import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule_bloc/bug_capsule_bloc.dart';
import 'package:bug_capsule_demo/main.dart';
import 'package:bug_capsule_demo/shop.dart';
import 'package:bug_capsule_flutter/bug_capsule_flutter.dart';
import 'package:bug_capsule_storage/bug_capsule_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The critical capture workflow on the real demo app: boot under BugCapsule, use
/// the app, raise a failure assertion, write a capsule, decode it.
void main() {
  testWidgets('the demo app runs under BugCapsule and captures a decodable, redacted capsule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('bugcapsule-demo-');
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir);
    await tester.runAsync(() => BugCapsule.init(
          config: const BugCapsuleConfig(
            appVersion: '1.0.0',
            appBuild: '1',
            mode: CaptureMode.qa,
            gitSha: 'smoke',
            autoCaptureOnFailure: false,
          ),
          integrations: [
            BugCapsuleBloc(states: [
              BugCapsuleState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
              BugCapsuleState<HomeCubit, HomeState>(toJson: (s) => s.toJson(), fromJson: HomeState.fromJson),
            ]),
            bugCapsuleDio,
            bugCapsuleRouter,
            BugCapsuleSharedPreferences(),
          ],
          appRunner: () => runApp(const ShopApp()),
        ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('BugCapsule Shop'), findsWidgets);
    expect(BugCapsule.isRecording, isTrue);

    await tester.tap(find.byKey(const Key('home.cart')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    BugCapsule.fail('smoke_check', 'upload failed token=synthDemoToken01');
    final result = await tester.runAsync(() => BugCapsule.capture(note: 'smoke'));
    final capsule = CapsuleCodec.decode(File(result!.file.path).readAsBytesSync());
    expect(capsule.manifest.integrations, ['bloc', 'dio', 'go_router', 'shared_preferences']);
    expect(capsule.manifest.failure!.assertionId, 'smoke_check');
    expect(capsule.manifest.failure!.message, isNot(contains('synthDemoToken01')));
    expect(capsule.eventsOfType(EventTypes.action).map((e) => e.data['id']), contains('home.cart'));
    expect(capsule.eventsOfType(EventTypes.http), isNotEmpty);
    expect(validateCapsuleDocument(CapsuleCodec.toJson(capsule)), isNull);

    await tester.runAsync(BugCapsule.resetForTest);
    BugCapsule.debugOverrides = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    dir.deleteSync(recursive: true);
  });
}
