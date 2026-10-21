import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:bug_capsule_core/bug_capsule_core.dart';

import 'actions.dart';
import 'integration.dart';

/// Downloads a capsule from the CLI and reports the result back.
class ReplayChannel {
  ReplayChannel(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Future<(Capsule, ReplaySettings)> fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final settingsRes = await (await client.getUrl(_uri(ReplayProtocol.settingsPath))).close();
      final settingsJson = jsonDecode(await utf8.decodeStream(settingsRes)) as Map;
      final capsuleRes = await (await client.getUrl(_uri(ReplayProtocol.capsulePath))).close();
      if (capsuleRes.statusCode != 200) {
        throw StateError('capsule download failed: HTTP ${capsuleRes.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in capsuleRes) {
        bytes.addAll(chunk);
      }
      return (
        CapsuleCodec.decode(bytes),
        ReplaySettings.fromJson(settingsJson.cast<String, Object?>()),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> report(ReplayReport report) async {
    final json = jsonEncode(report.toJson());
    // ignore: avoid_print
    print('${ReplayProtocol.stdoutPrefix}$json');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(_uri(ReplayProtocol.resultPath));
      req.headers.contentType = ContentType.json;
      req.write(json);
      await (await req.close()).drain<void>();
    } catch (e) {
      debugPrint('[bugcapsule] could not post replay result: $e');
    } finally {
      client.close(force: true);
    }
  }
}

/// Drives a replay: dispatches recorded input at recorded times, watches
/// for the original failure, and builds the [ReplayReport].
///
/// With [ReplaySettings.idleCompression], long idle gaps between inputs are
/// skipped (see [IdleCompressor]); the replay clock then runs ahead of real
/// time by [_skippedMs].
class ReplayEngine implements ReplayContext {
  ReplayEngine({
    required this.capsule,
    required this.settings,
    required this.actions,
    required this.buildGitSha,
  })  : fixtures = FixtureStore(capsule.events),
        _idle = IdleCompressor(capsule.events);

  @override
  final Capsule capsule;
  @override
  final ReplaySettings settings;
  @override
  final FixtureStore fixtures;
  final ActionRegistry actions;
  final String? buildGitSha;

  final Stopwatch _clock = Stopwatch();
  final List<Divergence> _divergences = [];
  final List<FailureRecord> _otherFailures = [];
  final Completer<FailureRecord> _reproduced = Completer();
  final Map<int, Offset> _lastPointerPosition = {};
  int _fixturesServed = 0;
  int _dispatched = 0;
  final IdleCompressor _idle;
  int _skippedMs = 0;
  int _gapsCompressed = 0;
  int _work = 0;
  int _lastActivityMs = 0;
  ReplayStrategy _strategy = ReplayStrategy.auto;

  /// Wall time (epoch ms) the replay clock returns before [start].
  int get _baseWallClockMs => capsule.checkpoint.wallClockMs;
  final Stopwatch _sinceRestore = Stopwatch()..start();

  /// Virtual wall clock: the recorded checkpoint time plus elapsed replay
  /// time (skipped idle time included), so `clock.now()` sees the same dates
  /// as during capture.
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(
      _baseWallClockMs + _sinceRestore.elapsedMilliseconds + _skippedMs);

  /// Replay clock in recorded milliseconds since [run] started.
  int elapsed() => _clock.elapsedMilliseconds + _skippedMs;

  @override
  void diverge(String type, String detail) {
    final t = _clock.isRunning ? elapsed() : null;
    if (_divergences.length < 200) _divergences.add(Divergence(type, detail, t: t));
  }

  @override
  void fixtureServed() => _fixturesServed++;

  @override
  void Function() beginWork() {
    _work++;
    activity();
    var ended = false;
    return () {
      if (ended) return;
      ended = true;
      _work--;
      activity();
    };
  }

  @override
  void activity() => _lastActivityMs = _clock.elapsedMilliseconds;

  /// How long running animations may hold up idle compression after the
  /// last activity: long enough for a route transition, short enough that an
  /// endless one (a blinking cursor, a spinner) does not pin replay to real
  /// time.
  static const _maxAnimationWaitMs = 2000;

  int get _quietMs => _clock.elapsedMilliseconds - _lastActivityMs;

  /// Work the app is still doing: pending responses, pressed pointers and
  /// recently started animations.
  int get _busy {
    final scheduler = SchedulerBinding.instance;
    final animating = scheduler.transientCallbackCount > 0 || scheduler.hasScheduledFrame;
    final settling = animating && _quietMs < _maxAnimationWaitMs;
    return _work + _lastPointerPosition.length + (settling ? 1 : 0);
  }

  void onFailure(FailureRecord failure) {
    final expected = capsule.manifest.failure;
    if (expected != null && failure.signature == expected.signature) {
      if (!_reproduced.isCompleted) _reproduced.complete(failure);
    } else {
      _otherFailures.add(failure);
      diverge('failure.other', failure.signature);
    }
  }

  /// Checks that can make replay pointless before the app even starts.
  ReplayReport? precheck() {
    final m = capsule.manifest;
    if (m.gitSha != null && buildGitSha != null && m.gitSha != buildGitSha) {
      diverge('build.gitSha', 'capsule ${m.gitSha} vs build $buildGitSha');
    }
    return null;
  }

  ReplayStrategy _chooseStrategy() {
    final hasPointers = capsule.events.any((e) => e.type == EventTypes.pointer);
    final hasActions = capsule.events.any((e) => e.type == EventTypes.action);
    switch (settings.strategy) {
      case ReplayStrategy.pointer:
      case ReplayStrategy.semantic:
        return settings.strategy;
      case ReplayStrategy.auto:
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final size = view.physicalSize / view.devicePixelRatio;
        final p = capsule.manifest.platform;
        final sameScreen = (size.width - p.screenWidth).abs() < 1 &&
            (size.height - p.screenHeight).abs() < 1;
        if (hasPointers && (sameScreen || !hasActions)) {
          if (!sameScreen) {
            diverge('screen.size',
                'recorded ${p.screenWidth}x${p.screenHeight}, replay ${size.width}x${size.height}; pointers are scaled');
          }
          return ReplayStrategy.pointer;
        }
        return ReplayStrategy.semantic;
    }
  }

  /// Call after the first frame of the replayed app.
  Future<ReplayReport> run() async {
    _clock.start();
    _strategy = _chooseStrategy();
    final expected = capsule.manifest.failure;
    final base = capsule.checkpoint.kind == CheckpointKind.launch ? 0 : capsule.checkpoint.t;

    final toDispatch = [
      for (final e in capsule.events)
        if (_shouldDispatch(e.type) && e.t >= base) e,
    ];

    var lastT = 0;
    var previous = base;
    for (final event in toDispatch) {
      if (_reproduced.isCompleted) break;
      final due = event.t - base;
      lastT = due;
      final idleSince = settings.idleCompression ? _idle.idleSince(previous, event.t) : null;
      previous = event.t;
      while (!_reproduced.isCompleted) {
        final wait = due - elapsed();
        if (wait <= 0) break;
        if (idleSince != null &&
            _idle.maySkip(
              now: elapsed() + base,
              idleSince: idleSince,
              busy: _busy,
              quietMs: _quietMs,
            )) {
          _skippedMs += wait;
          _gapsCompressed++;
          break;
        }
        // Inside a compressible gap, re-check idleness every 50 ms.
        final step = idleSince == null || wait < 50 ? wait : 50;
        await Future.any([Future<void>.delayed(Duration(milliseconds: step)), _reproduced.future]);
      }
      if (_reproduced.isCompleted) break;
      _dispatch(event);
    }

    FailureRecord? observed;
    if (!_reproduced.isCompleted) {
      final failureDue = expected == null ? 0 : expected.t - base;
      final deadline = (failureDue > lastT ? failureDue : lastT) +
          (expected == null ? 1500 : settings.settleTimeoutMs);
      final remaining = deadline - elapsed();
      if (remaining > 0) {
        observed = await _reproduced.future
            .timeout(Duration(milliseconds: remaining), onTimeout: () => _notObserved);
        if (identical(observed, _notObserved)) observed = null;
      }
    } else {
      observed = await _reproduced.future;
    }

    for (final key in fixtures.unusedKeys()) {
      diverge('network.unused', key);
    }

    final outcome = expected == null
        ? ReplayOutcome.noAssertion
        : observed != null
            ? ReplayOutcome.reproduced
            : ReplayOutcome.notReproduced;
    return ReplayReport(
      outcome: outcome,
      attempt: settings.attempt,
      durationMs: _clock.elapsedMilliseconds,
      strategy: _strategy,
      expectedSignature: expected?.signature,
      observed: observed,
      otherFailures: List.of(_otherFailures),
      divergences: List.of(_divergences),
      eventsDispatched: _dispatched,
      eventsExpected: toDispatch.length,
      fixturesServed: _fixturesServed,
      compressedMs: _skippedMs,
      gapsCompressed: _gapsCompressed,
      buildGitSha: buildGitSha,
    );
  }

  static final _notObserved =
      FailureRecord.assertion('__bugcapsule_not_observed__', '', 0);

  bool _shouldDispatch(String type) => switch (type) {
        EventTypes.lifecycle || EventTypes.text => true,
        EventTypes.pointer => _strategy == ReplayStrategy.pointer,
        EventTypes.action => _strategy == ReplayStrategy.semantic,
        _ => false,
      };

  void _dispatch(BugCapsuleEvent event) {
    try {
      switch (event.type) {
        case EventTypes.pointer:
          _dispatchPointer(event.data);
        case EventTypes.action:
          final id = event.data['id'] as String;
          final payload = (event.data['payload'] as Map?)?.cast<String, Object?>();
          if (!actions.invoke(id, payload)) {
            diverge('action.unregistered', id);
            return;
          }
        case EventTypes.text:
          final id = event.data['id'] as String;
          final value = event.data['value'] as String? ?? '';
          if (value.contains(Redactor.placeholder)) diverge('text.redacted', id);
          if (!actions.setText(id, value)) {
            diverge('text.untracked', id);
            return;
          }
        case EventTypes.lifecycle:
          final state = AppLifecycleState.values.byName(event.data['state'] as String);
          // ignore: invalid_use_of_protected_member
          WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
      }
      _dispatched++;
      activity();
    } catch (e) {
      diverge('dispatch.error', '${event.type}: $e');
    }
  }

  void _dispatchPointer(Map<String, Object?> d) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final p = capsule.manifest.platform;
    final sx = p.screenWidth > 0 ? size.width / p.screenWidth : 1.0;
    final sy = p.screenHeight > 0 ? size.height / p.screenHeight : 1.0;
    final position = Offset((d['x'] as num).toDouble() * sx, (d['y'] as num).toDouble() * sy);
    final pointer = 100000 + (d['pointer'] as int);
    final kind = PointerDeviceKind.values.asNameMap()[d['kind']] ?? PointerDeviceKind.touch;
    final buttons = d['buttons'] as int? ?? kPrimaryButton;
    final ts = Duration(milliseconds: _clock.elapsedMilliseconds);
    final last = _lastPointerPosition[pointer] ?? position;

    final PointerEvent event = switch (d['phase']) {
      'down' => PointerDownEvent(
          timeStamp: ts, pointer: pointer, kind: kind, position: position, buttons: buttons),
      'move' => PointerMoveEvent(
          timeStamp: ts,
          pointer: pointer,
          kind: kind,
          position: position,
          delta: position - last,
          buttons: buttons),
      'up' => PointerUpEvent(timeStamp: ts, pointer: pointer, kind: kind, position: position),
      _ => PointerCancelEvent(timeStamp: ts, pointer: pointer, kind: kind, position: position),
    };
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _lastPointerPosition.remove(pointer);
    } else {
      _lastPointerPosition[pointer] = position;
    }
    GestureBinding.instance.handlePointerEvent(event);
  }
}
