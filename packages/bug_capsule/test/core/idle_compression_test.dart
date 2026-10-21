import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

BugCapsuleEvent ev(int t, String type, [Map<String, Object?> data = const {}]) =>
    BugCapsuleEvent(seq: t, t: t, type: type, data: data);

BugCapsuleEvent http(int t, int durationMs) => ev(t, EventTypes.http, {'durationMs': durationMs});

void main() {
  group('IdleCompressor.idleSince', () {
    test('short gaps are never idle', () {
      final c = IdleCompressor([ev(0, EventTypes.action), ev(1500, EventTypes.action)]);
      expect(c.idleSince(0, 1500), isNull);
    });

    test('a quiet gap is idle from the previous input', () {
      final c = IdleCompressor([ev(0, EventTypes.action), ev(20000, EventTypes.action)]);
      expect(c.idleSince(0, 20000), 0);
    });

    test('recorded activity pushes the idle start back', () {
      final c = IdleCompressor([
        ev(0, EventTypes.action),
        ev(10, EventTypes.blocEvent),
        ev(900, EventTypes.blocState),
        ev(9000, EventTypes.action),
      ]);
      expect(c.idleSince(0, 9000), 900);
    });

    test('activity late in the gap leaves too little idle time', () {
      final c = IdleCompressor([
        ev(0, EventTypes.action),
        ev(8000, EventTypes.log),
        ev(9000, EventTypes.action),
      ]);
      expect(c.idleSince(0, 9000), isNull);
    });

    test('network latency is never idle, measured from request to response', () {
      // Response at 7000 after 6500 ms: the request went out at 500.
      final c = IdleCompressor(
          [ev(0, EventTypes.action), http(7000, 6500), ev(9000, EventTypes.action)]);
      expect(c.idleSince(0, 9000), 7000 /* only 2 s after the response */);
      expect(IdleCompressor([http(7000, 6500)]).idleSince(0, 8000), isNull);
    });

    test('a request still in flight at the input blocks the gap', () {
      // Sent at 1000, answered at 12000; the input at 9000 races it.
      final c = IdleCompressor([ev(0, EventTypes.action), http(12000, 11000)]);
      expect(c.idleSince(0, 9000), isNull);
    });

    test('events after the input are ignored', () {
      final c = IdleCompressor(
          [ev(0, EventTypes.action), ev(9000, EventTypes.action), ev(9500, EventTypes.blocState)]);
      expect(c.idleSince(0, 9000), 0);
    });

    test('uses the configured threshold', () {
      final c = IdleCompressor([ev(0, EventTypes.action)], minGapMs: 5000);
      expect(c.idleSince(0, 5000), isNull);
      expect(c.idleSince(0, 5001), 0);
    });
  });

  group('IdleCompressor.maySkip', () {
    final c = IdleCompressor(const []);

    test('skips once the replay is past the idle start and the app is quiet', () {
      expect(c.maySkip(now: 1300, idleSince: 1000, busy: 0, quietMs: 300), isTrue);
    });

    test('waits ~300 ms into the idle stretch', () {
      expect(c.maySkip(now: 1299, idleSince: 1000, busy: 0, quietMs: 5000), isFalse);
    });

    test('waits while work is pending', () {
      expect(c.maySkip(now: 5000, idleSince: 1000, busy: 1, quietMs: 5000), isFalse);
    });

    test('waits for recent activity to settle', () {
      expect(c.maySkip(now: 5000, idleSince: 1000, busy: 0, quietMs: 299), isFalse);
    });
  });

  test('ReplaySettings and ReplayReport carry idle compression', () {
    expect(const ReplaySettings().idleCompression, isTrue);
    expect(ReplaySettings.fromJson(const {}).idleCompression, isTrue);
    expect(
        ReplaySettings.fromJson(const ReplaySettings(idleCompression: false).toJson())
            .idleCompression,
        isFalse);
    final report = ReplayReport.fromJson(const ReplayReport(
      outcome: ReplayOutcome.reproduced,
      attempt: 1,
      durationMs: 4000,
      strategy: ReplayStrategy.pointer,
      compressedMs: 30000,
      gapsCompressed: 2,
    ).toJson());
    expect(report.compressedMs, 30000);
    expect(report.gapsCompressed, 2);
  });
}
