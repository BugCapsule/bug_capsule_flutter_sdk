import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_demo/main.dart' as app;
import 'package:bug_capsule_demo/shop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device capture records coupon assertion', (tester) async {
    app.main();
    Future<void> waitFor(Finder finder) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(finder, findsOneWidget);
      await tester.pumpAndSettle();
    }

    final home = find.byKey(const Key('home.cart'));
    await waitFor(home);
    for (var attempt = 0; attempt < 15; attempt++) {
      await tester.tap(home);
      final field = find.byKey(const Key('cart.coupon'));
      await waitFor(field);
      final bloc = tester.element(field).read<CartBloc>();
      if (bloc.state.subtotal >= 100) {
        await tester.pageBack();
        await waitFor(home);
        continue;
      }
      await tester.enterText(field, 'SAVE100');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final apply = find.byKey(const Key('cart.applyCoupon'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(bloc.state.total, lessThan(0));
      final result = await BugCapsule.capture(
        note: 'device release validation',
      );
      expect(result, isNotNull);
      final capsule = CapsuleCodec.decode(await result!.file.readAsBytes());
      expect(capsule.manifest.failure?.assertionId, 'cart_total_non_negative');
      return;
    }
    fail('No cart below coupon value in 15 attempts');
  });
}
