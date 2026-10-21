import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:repro_flutter/repro_flutter.dart';
import 'package:repro_storage/repro_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSession implements ReproSession {
  FakeSession({this.replay});
  @override
  final ReplayContext? replay;
  @override
  ReproConfig get config => const ReproConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => replay == null;
  @override
  bool get isReplaying => replay != null;
  @override
  final Redactor redactor = Redactor();
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 1024;
  @override
  int now() => 0;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) {}
  @override
  void reportError(Object error, StackTrace? stack) {}
}

class FakeReplay implements ReplayContext {
  final List<String> divergences = [];
  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshots redact sensitive keys and secrets inside JSON string values', () async {
    SharedPreferences.setMockInitialValues({
      'session_token': 'synthStoredToken1',
      'auth_state': jsonEncode({'accessToken': 'synthStoredToken2', 'user': 'ann'}),
      'recent': ['ok', 'Bearer synthStoredBearer3'],
      'theme': 'dark',
      'launches': 3,
    });
    final storage = ReproSharedPreferences();
    await storage.setUp(FakeSession());
    final snapshot = await storage.snapshot(CheckpointKind.launch) as Map;
    final raw = jsonEncode(snapshot);
    for (final s in ['synthStoredToken1', 'synthStoredToken2', 'synthStoredBearer3']) {
      expect(raw, isNot(contains(s)));
    }
    expect((snapshot['theme'] as Map)['value'], 'dark');
    expect((snapshot['launches'] as Map)['value'], 3);
    expect(jsonDecode((snapshot['auth_state'] as Map)['value'] as String), {'accessToken': '[REDACTED]', 'user': 'ann'});

    final eligibility = EligibilityBuilder();
    storage.describeEligibility(eligibility, const RecordedWindow(
        checkpoint: Checkpoint(kind: CheckpointKind.launch, t: 0, wallClockMs: 0, afterSeq: 0),
        events: [], droppedEvents: 0, hasGap: false));
    expect(eligibility.build().missing.map((m) => m.dependency),
        containsAll(['storage.session_token', 'storage.auth_state', 'storage.recent']));
  });

  test('restore reports redacted entries instead of failing', () async {
    SharedPreferences.setMockInitialValues({});
    final replay = FakeReplay();
    final storage = ReproSharedPreferences();
    await storage.restore({
      'auth_token': '[REDACTED]',
      'pin': {'type': 'string', 'value': '[REDACTED]'},
      'theme': {'type': 'string', 'value': 'dark'},
    }, FakeSession(replay: replay));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme'), 'dark');
    expect(replay.divergences, containsAll(['storage.redacted auth_token', 'storage.redacted pin']));
  });
}
