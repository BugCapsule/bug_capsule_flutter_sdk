import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'native.dart';
import 'surface.dart';

/// A module the app ships a fallback for, and that patches may replace. The
/// schemas are canonical type text (`int`, `dec(2)`, `rec(a:int,b:str)`); a
/// patch must implement exactly these to activate.
final class PatchModule<I, O> {
  const PatchModule({
    required this.id,
    required this.inputSchema,
    required this.outputSchema,
    required this.encode,
    required this.decode,
    required this.fallback,
  });

  final String id;
  final String inputSchema;
  final String outputSchema;
  final Object? Function(I input) encode;
  final O Function(Object? output) decode;

  /// The bundled implementation. Runs whenever no patch applies or one fails.
  final O Function(I input) fallback;
}

/// Where a [PatchResult] came from.
enum PatchSource { patched, bundled }

final class PatchResult<O> {
  const PatchResult(this.value, this.source, {this.reason});

  final O value;
  final PatchSource source;

  /// Why the bundled implementation ran: `not_patched`, or an error code such
  /// as `fuel_exhausted`.
  final String? reason;
}

/// Identity of the installed binary and where its patches come from.
final class PatchConfig {
  const PatchConfig({
    required this.storeDir,
    required this.projectId,
    required this.applicationId,
    required this.environment,
    required this.platform,
    required this.distributionProfile,
    required this.baseBuildId,
    required this.installationId,
    required this.trustRoots,
  });

  final String storeDir;
  final String projectId;
  final String applicationId;
  final String environment;

  /// `flutter_android` or `flutter_ios`.
  final String platform;

  /// `development`, `internal` or `public_*`. Non-development profiles only
  /// accept artifacts that signed channel metadata authorizes.
  final String distributionProfile;

  /// Generated at build time; never the marketing version.
  final String baseBuildId;

  /// Stable pseudonymous id for cohort assignment.
  final String installationId;

  /// Pinned `bcpk.v1.…` keys.
  final List<String> trustRoots;
}

/// The runtime as the app sees it. One generation is pinned at [open] for the
/// life of the process: staging never changes running behavior.
final class BugCapsulePatch {
  BugCapsulePatch._(this._native, this._engine, this.unavailableReason);

  final Native? _native;
  Pointer<Void>? _engine;

  /// Why this build runs fallbacks only; null when the runtime is up.
  final String? unavailableReason;

  bool get available => _engine != null;

  /// Opens the store and selects the generation for this process. Never
  /// throws: without a usable runtime every [call] uses the fallback.
  static BugCapsulePatch open(PatchConfig config, {required List<PatchModule<dynamic, dynamic>> modules, List<PatchSurfaceContract> surfaces = const [], String? libraryPath}) {
    final native = Native.load(libraryPath);
    if (native == null) return BugCapsulePatch._(null, null, 'runtime_missing');
    if (native.version != abiVersion) return BugCapsulePatch._(null, null, 'abi_mismatch');
    final json = jsonEncode({
      'storeDir': config.storeDir,
      'projectId': config.projectId,
      'applicationId': config.applicationId,
      'environment': config.environment,
      'platform': config.platform,
      'distributionProfile': config.distributionProfile,
      'baseBuildId': config.baseBuildId,
      'installationId': config.installationId,
      'trustRoots': config.trustRoots,
      'modules': [
        for (final m in modules) {'id': m.id, 'input': m.inputSchema, 'output': m.outputSchema},
      ],
      'surfaces': [for (final s in surfaces) s.toJson()],
    });
    try {
      return BugCapsulePatch._(native, native.open(utf8.encode(json)), null);
    } on NativeError catch (e) {
      return BugCapsulePatch._(native, null, e.code);
    }
  }

  /// Runs the patched module when this generation has one, and otherwise the
  /// bundled fallback. Never throws for a patch failure.
  PatchResult<O> call<I, O>(PatchModule<I, O> module, I input, {int timeoutMs = 50}) {
    final engine = _engine;
    if (engine == null) return PatchResult(module.fallback(input), PatchSource.bundled, reason: unavailableReason);
    try {
      final body = _native!.call(engine, opEval, a: utf8.encode(module.id), b: utf8.encode(jsonEncode(module.encode(input))), n: timeoutMs);
      final decoded = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      return PatchResult(module.decode(decoded['output']), PatchSource.patched);
    } on NativeError catch (e) {
      return PatchResult(module.fallback(input), PatchSource.bundled, reason: e.code);
    } on Object {
      return PatchResult(module.fallback(input), PatchSource.bundled, reason: 'bad_output');
    }
  }

  Map<String, Object?> _json(int op, {List<int> a = const [], List<int> b = const [], int n = 0}) {
    final engine = _engine;
    if (engine == null) throw NativeError('unavailable', unavailableReason ?? 'closed');
    return jsonDecode(utf8.decode(_native!.call(engine, op, a: a, b: b, n: n))) as Map<String, Object?>;
  }

  Map<String, Object?> status() => _json(opStatus);

  /// Verifies a `.bcpatch` and makes it the next launch's candidate.
  Map<String, Object?> stage(Uint8List bundle) => _json(opStage, a: bundle);

  /// Applies signed channel metadata; the answer says what to do next.
  Map<String, Object?> applyChannel(Uint8List document, Uint8List signature) => _json(opChannel, a: document, b: signature);

  Map<String, Object?> applyKeyring(Uint8List document, Uint8List signature) => _json(opKeyring, a: document, b: signature);

  /// Call after the first usable screen and module smoke checks. Reaching
  /// this is what commits a candidate; downloading it is not health.
  Map<String, Object?> markHealthy(String checkpoint) => _json(opHealthy, a: utf8.encode(checkpoint));

  /// Reports a fault attributed to the running patch, such as a crash.
  Map<String, Object?> reportFault(String kind) => _json(opFault, a: utf8.encode(kind));

  Map<String, Object?> receipts() => _json(opReceipts);

  Map<String, Object?> ackReceipts(int upTo) => _json(opAck, n: upTo);

  /// A patched asset, or null when this generation does not override [id].
  Uint8List? asset(String id) {
    final engine = _engine;
    if (engine == null) return null;
    try {
      return _native!.call(engine, opAsset, a: utf8.encode(id));
    } on NativeError {
      return null;
    }
  }

  /// The patched document for a registered surface, or null to use the
  /// bundled layout. Render it with `PatchSurfaceView`.
  Uint8List? surface(String id) {
    final engine = _engine;
    if (engine == null) return null;
    try {
      return _native!.call(engine, opSurface, a: utf8.encode(id));
    } on NativeError {
      return null;
    }
  }

  void close() {
    final engine = _engine;
    if (engine != null) _native!.close(engine);
    _engine = null;
  }
}
