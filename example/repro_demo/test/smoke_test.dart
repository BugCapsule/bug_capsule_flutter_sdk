import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:repro_bloc/repro_bloc.dart';
import 'package:repro_demo/main.dart';
import 'package:repro_demo/shop.dart';
import 'package:repro_flutter/repro_flutter.dart';
import 'package:repro_storage/repro_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The critical capture workflow on the real demo app: boot under Repro, use
/// the app, raise a failure assertion, write a capsule, decode it.
void main() {
  testWidgets('the demo app runs under Repro and captures a decodable, redacted capsule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('repro-demo-');
    Repro.debugOverrides = ReproTestOverrides(storageDirectory: dir);
    await tester.runAsync(() => Repro.init(
          config: const ReproConfig(
            appVersion: '1.0.0',
            appBuild: '1',
            mode: CaptureMode.qa,
            gitSha: 'smoke',
            autoCaptureOnFailure: false,
          ),
          integrations: [
            ReproBloc(states: [
              ReproState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
              ReproState<HomeCubit, HomeState>(toJson: (s) => s.toJson(), fromJson: HomeState.fromJson),
            ]),
            reproDio,
            reproRouter,
            ReproSharedPreferences(),
          ],
          appRunner: () => runApp(const ShopApp()),
        ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Repro Shop'), findsWidgets);
    expect(Repro.isRecording, isTrue);

    await tester.tap(find.byKey(const Key('home.cart')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    Repro.fail('smoke_check', 'upload failed token=synthDemoToken01');
    final result = await tester.runAsync(() => Repro.capture(note: 'smoke'));
    final capsule = CapsuleCodec.decode(File(result!.file.path).readAsBytesSync());
    expect(capsule.manifest.integrations, ['bloc', 'dio', 'go_router', 'shared_preferences']);
    expect(capsule.manifest.failure!.assertionId, 'smoke_check');
    expect(capsule.manifest.failure!.message, isNot(contains('synthDemoToken01')));
    expect(capsule.eventsOfType(EventTypes.action).map((e) => e.data['id']), contains('home.cart'));
    expect(capsule.eventsOfType(EventTypes.http), isNotEmpty);
    expect(validateCapsuleDocument(CapsuleCodec.toJson(capsule)), isNull);

    await tester.runAsync(Repro.resetForTest);
    Repro.debugOverrides = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    dir.deleteSync(recursive: true);
  });
}
