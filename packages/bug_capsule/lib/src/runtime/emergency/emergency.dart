import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../version.dart';
import '../config.dart' show BugCapsuleBackendConfig;
import '../connection_token.dart';
import 'contract.dart';
import 'engine.dart';
import 'hotfix.dart';
import 'store.dart';
import 'transport.dart';
import 'types.dart';

/// What the emergency module needs from the rest of the SDK. Implemented by
/// `BugCapsule`; not part of the public API.
abstract interface class EmergencyHost {
  /// The connection of `BugCapsule.init`, whether or not capture is on.
  BugCapsuleBackendConfig? get backend;

  /// A capsule is being replayed (§7.4).
  bool get isReplaying;

  /// `BugCapsuleConfig.appVersion`, or the `BUGCAPSULE_APP_VERSION`
  /// dart-define before `BugCapsule.init`; null when unknown.
  String? get appVersion;

  /// The SDK storage root replaced in tests (`BugCapsuleTestOverrides`).
  Directory? get storageDirectory;
}

/// Replaces storage, platform, clock, randomness and transport in tests.
@visibleForTesting
class EmergencyTestOverrides {
  const EmergencyTestOverrides({
    this.storageDirectory,
    this.platform,
    this.now,
    this.random,
    this.transport,
  });

  /// The SDK storage root; policies are kept in its `emergency/` folder.
  final Directory? storageDirectory;

  /// The host platform; return null to simulate an unsupported one.
  final EmergencyPlatform? Function()? platform;
  final DateTime Function()? now;

  /// Jitter of retries.
  final Random? random;
  final EmergencyTransport? transport;
}

/// Remote feature guards (`BugCapsule.emergency`): signed emergency
/// policies fetched from BugCapsule, verified against the trust anchor
/// compiled into the app, cached, and evaluated locally.
///
/// ```dart
/// await BugCapsule.emergency.initialize(const EmergencyConfig(
///   trustAnchor: 'bcek.v1.…',
///   failureModes: {'checkout.*': EmergencyFailureMode.failClosed},
/// ));
/// final decision = BugCapsule.emergency.evaluate('checkout.confirm_order');
/// if (!decision.allowed) showUnavailable(decision.publicUserMessage);
/// ```
///
/// Nothing executable is downloaded: a policy only says whether a named
/// feature may run and what to show instead. A client guard improves the
/// user experience; the app's server must enforce the same restriction for
/// anything that moves money or data.
///
/// Every method is safe to call at any time and never throws: before
/// [initialize], with an invalid anchor, on an unsupported platform, or
/// when anything fails, evaluations return the feature's failure mode.
final class BugCapsuleEmergency {
  /// Use `BugCapsule.emergency`; this constructor is for the SDK and its
  /// tests.
  @internal
  BugCapsuleEmergency.internal(this._host);

  final EmergencyHost _host;

  @visibleForTesting
  EmergencyTestOverrides? debugOverrides;

  EmergencyConfig? _config;
  EmergencyFailureModes _modes = EmergencyFailureModes.defaults;
  EmergencyEngine? _engine;
  String? _inactiveReason;
  Future<void>? _initializing;
  BugCapsuleBackendConfig? _configuredBackend;
  _LifecycleObserver? _observer;
  WidgetsBinding? _observedBinding;
  EmergencyHotfix? _hotfix;
  Map<String, Object?>? _runtime;
  StreamController<EmergencySnapshot> _changes =
      StreamController<EmergencySnapshot>.broadcast();
  final Set<String> _warned = {};

  void _warnOnce(String message) {
    if (_warned.add(message)) debugPrint('[bugcapsule] emergency: $message');
  }

  // ---------------------------------------------------------------- setup

  /// Starts the module: parses the trust anchor, restores and re-verifies
  /// the cached document, publishes it and starts the first fetch in the
  /// background. Completes without waiting for the network. A second call
  /// is ignored.
  Future<void> initialize(EmergencyConfig config) {
    if (_config != null) {
      _warnOnce('initialize was called again; the first configuration stays');
      return _initializing ?? Future.value();
    }
    _config = config;
    final provider = config.hotfixProvider;
    if (provider != null) {
      _hotfix = EmergencyHotfix.internal(provider, _hotfixStatus);
    }
    return _initializing = _initialize(config).catchError((Object e) {
      _inactiveReason = 'setup_failed';
      _warnOnce('setup failed, failure modes apply: $e');
    });
  }

  Future<void> _initialize(EmergencyConfig config) async {
    _modes = EmergencyFailureModes(config.failureModes);
    final EmergencyTrustAnchor anchor;
    try {
      anchor = EmergencyTrustAnchor.parse(config.trustAnchor);
    } on FormatException catch (e) {
      _inactiveReason = 'invalid_anchor';
      _warnOnce(
        'the trust anchor is invalid (${e.message}); emergency policies '
        'are off and every feature uses its failure mode',
      );
      return;
    }
    if (!isEmergencyEnvironment(config.environment)) {
      _inactiveReason = 'invalid_environment';
      _warnOnce(
        'environment "${config.environment}" is invalid; emergency '
        'policies are off and every feature uses its failure mode',
      );
      return;
    }
    final overrides = debugOverrides;
    final platform = overrides?.platform != null
        ? overrides!.platform!()
        : _hostPlatform();
    if (platform == null) {
      _inactiveReason = 'unsupported_platform';
      _warnOnce(
        'emergency policies run on Android and iOS only; every feature '
        'uses its failure mode on this platform',
      );
      return;
    }
    if (_host.isReplaying) {
      _inactiveReason = 'replay';
      return;
    }
    _configuredBackend = _resolveConfiguredBackend(config);

    EmergencyStore? store;
    try {
      final root =
          overrides?.storageDirectory ??
          _host.storageDirectory ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/bugcapsule',
          );
      store = await EmergencyStore.open(Directory('${root.path}/emergency'));
    } catch (e) {
      _warnOnce('storage unavailable, policies are kept in memory only: $e');
    }
    String installationId;
    try {
      installationId =
          await store?.installationId(Random.secure()) ??
          newInstallationId(Random.secure());
    } catch (e) {
      _warnOnce('could not persist the installation id: $e');
      installationId = newInstallationId(Random.secure());
    }

    final engine = _engine = EmergencyEngine(
      anchor: anchor,
      environment: config.environment,
      platform: platform,
      refreshInterval: config.effectiveRefreshInterval,
      failureModes: _modes,
      store: store,
      transport: overrides?.transport ?? const HttpEmergencyTransport(),
      connection: _connection,
      appVersion: _appVersion,
      sdkVersion: bugCapsuleVersion,
      installationId: installationId,
      isReplaying: () => _host.isReplaying,
      onSnapshot: _emit,
      now: overrides?.now,
      random: overrides?.random,
    );
    final runtime = _runtime;
    if (runtime != null) engine.updateRuntime(runtime);
    _observeLifecycle();
    await engine.start();
    // The first report says whether this build can be patched at all.
    unawaited(_hotfix?.getStatus());
  }

  static EmergencyPlatform? _hostPlatform() {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return EmergencyPlatform.flutterAndroid;
    if (Platform.isIOS) return EmergencyPlatform.flutterIos;
    return null;
  }

  /// An explicit backend wins over a token; an unusable token is reported
  /// and leaves the module without a connection.
  BugCapsuleBackendConfig? _resolveConfiguredBackend(EmergencyConfig config) {
    final backend = config.backend;
    if (backend != null) return backend;
    final token = config.token;
    if (token == null) return null;
    switch (parseConnectionToken(token)) {
      case ValidConnectionToken(:final backend):
        return backend;
      case final InvalidConnectionToken error:
        _warnOnce(
          "the SDK token can't be used (${error.error.code}): "
          '${error.message}',
        );
        return null;
    }
  }

  bool get _hasConfiguredConnection {
    final c = _config;
    return c != null && (c.backend != null || c.token != null);
  }

  BugCapsuleBackendConfig? _connection() =>
      _hasConfiguredConnection ? _configuredBackend : _host.backend;

  String? _appVersion() {
    final v = _config?.appVersion ?? _host.appVersion;
    return v == null || v.isEmpty ? null : v;
  }

  /// Every status the hotfix provider returns updates the runtime report
  /// (§7.6); one that cannot be reported is logged once and dropped.
  void _hotfixStatus(HotfixStatus status) {
    final Map<String, Object?> runtime;
    try {
      runtime = {'hotfix': hotfixRuntimeJson(status, _appVersion())};
    } on FormatException catch (e) {
      _warnOnce('hotfix status not reported: ${e.message}');
      return;
    }
    _runtime = runtime;
    _engine?.updateRuntime(runtime);
  }

  void _emit(EmergencySnapshot snapshot) {
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  /// `BugCapsule.init` started: lifecycle can now be observed, and a module
  /// waiting for a connection fetches.
  void runtimeAttached() {
    try {
      _observeLifecycle();
      final engine = _engine;
      if (engine != null &&
          !_hasConfiguredConnection &&
          engine.status().lastError?.code == 'not_connected') {
        unawaited(engine.refresh());
      }
    } catch (e) {
      _warnOnce('could not attach to BugCapsule: $e');
    }
  }

  void _observeLifecycle() {
    final engine = _engine;
    if (engine == null || _observer != null) return;
    WidgetsBinding? binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      return; // No binding yet: attached again from `BugCapsule.init`.
    }
    final observer = _observer = _LifecycleObserver(engine);
    _observedBinding = binding;
    binding.addObserver(observer);
    final state = binding.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      engine.onPaused();
    }
  }

  // ------------------------------------------------------------- queries

  /// The decision for [featureKey] (`checkout.confirm_order`), synchronous
  /// and from memory. [subject] is the rollout subject, by default the
  /// installation id; pass only a stable pseudonymous id, never an email
  /// address or anything else that identifies a person.
  EmergencyDecision evaluate(String featureKey, {String? subject}) {
    try {
      if (_host.isReplaying) return emergencyReplayDecision(featureKey);
      if (!isEmergencyFeatureKey(featureKey)) {
        _warnOnce(
          '"$featureKey" is not a feature key (lower-case dotted names); '
          'no policy can match it',
        );
      }
      final engine = _engine;
      if (engine == null) {
        return emergencyFailureDecision(featureKey, _modes.modeFor(featureKey));
      }
      return engine.evaluate(featureKey, subject: subject);
    } catch (e) {
      _warnOnce('evaluation failed, the failure mode applies: $e');
      try {
        return emergencyFailureDecision(featureKey, _modes.modeFor(featureKey));
      } catch (_) {
        return emergencyFailureDecision(
          featureKey,
          EmergencyFailureMode.failOpen,
        );
      }
    }
  }

  /// The hotfix adapter of [EmergencyConfig.hotfixProvider]; null without
  /// one or before [initialize]. Its calls go to the provider, and every
  /// status they return is reported to the BugCapsule backend (§7.6). A
  /// downloaded patch becomes active on the next start; the app is never
  /// restarted.
  EmergencyHotfix? get hotfix => _hotfix;

  /// Whether [evaluate] allows [featureKey].
  bool isFeatureAllowed(String featureKey, {String? subject}) =>
      evaluate(featureKey, subject: subject).allowed;

  /// The policy that decides [featureKey], or null when none does (no
  /// matching policy, a failure mode, or replay).
  EmergencyPolicy? getPolicy(String featureKey, {String? subject}) =>
      evaluate(featureKey, subject: subject).policy;

  /// Fetches policies now; joins a fetch already running. Completes when
  /// the fetch is done; never throws.
  Future<void> refreshPolicies() async {
    try {
      await _initializing;
      _observeLifecycle();
      await _engine?.refresh();
    } catch (e) {
      _warnOnce('refresh failed: $e');
    }
  }

  /// Snapshots as they change: a new document, or a document or policy
  /// expiring. Delivered asynchronously after the swap, on the main
  /// isolate; an observer that throws does not affect the module.
  Stream<EmergencySnapshot> get changes => _changes.stream;

  /// The document evaluations currently use.
  EmergencySnapshot get snapshot =>
      _engine?.snapshot ?? EmergencySnapshot.empty;

  EmergencyStatus get status {
    final engine = _engine;
    if (_host.isReplaying) {
      return EmergencyStatus(
        initialized: _config != null,
        active: false,
        state: EmergencyDocumentState.none,
        inactiveReason: 'replay',
        environment: _config?.environment,
      );
    }
    if (engine != null) return engine.status();
    return EmergencyStatus(
      initialized: _config != null,
      active: false,
      state: EmergencyDocumentState.none,
      inactiveReason: _inactiveReason,
      environment: _config?.environment,
    );
  }

  /// The engine, for tests that drive its lifecycle and wait for writes.
  @visibleForTesting
  EmergencyEngine? get debugEngine => _engine;

  /// Back to the state before [initialize]; pending fetches are dropped.
  @visibleForTesting
  Future<void> resetForTest() async {
    try {
      await _initializing;
    } catch (_) {}
    final engine = _engine;
    _engine = null;
    engine?.dispose();
    await engine?.flush();
    final observer = _observer;
    if (observer != null) _observedBinding?.removeObserver(observer);
    _observer = null;
    _observedBinding = null;
    _config = null;
    _modes = EmergencyFailureModes.defaults;
    _inactiveReason = null;
    _initializing = null;
    _configuredBackend = null;
    _hotfix = null;
    _runtime = null;
    _warned.clear();
    await _changes.close();
    _changes = StreamController<EmergencySnapshot>.broadcast();
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this.engine);
  final EmergencyEngine engine;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      switch (state) {
        case AppLifecycleState.resumed:
          engine.onResumed();
        case AppLifecycleState.paused ||
            AppLifecycleState.hidden ||
            AppLifecycleState.detached:
          engine.onPaused();
        case AppLifecycleState.inactive:
          break;
      }
    } catch (e) {
      debugPrint('[bugcapsule] emergency: lifecycle handling failed: $e');
    }
  }
}
