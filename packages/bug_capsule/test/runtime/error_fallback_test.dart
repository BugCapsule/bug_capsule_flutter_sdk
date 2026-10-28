import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/error_fallback.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a real build failure renders the safe replacement', (
    tester,
  ) async {
    final previous = ErrorWidget.builder;
    ErrorWidget.builder = (_) => const BugCapsuleErrorFallback();
    try {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (_) => throw StateError('private-widget-detail'),
          ),
        ),
      );
      expect(tester.takeException(), isA<StateError>());
      expect(find.textContaining('could not load'), findsOneWidget);
      expect(find.textContaining('private-widget-detail'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      ErrorWidget.builder = previous;
    }
  });

  test('capture UI is opt-in and forbidden in production', () {
    for (final mode in CaptureMode.values) {
      expect(BugCapsuleConfig(mode: mode).showOverlay, isFalse);
    }
    expect(
      const BugCapsuleConfig(
        mode: CaptureMode.qa,
        showOverlay: true,
      ).showOverlay,
      kReleaseMode ? isFalse : isTrue,
    );
    expect(
      const BugCapsuleConfig(
        mode: CaptureMode.production,
        showOverlay: true,
      ).showOverlay,
      isFalse,
    );
  });

  testWidgets(
    'fallback works without MaterialApp and in small failed regions',
    (tester) async {
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 100,
            height: 40,
            child: BugCapsuleErrorFallback(),
          ),
        ),
      );
      expect(find.textContaining('could not load'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
