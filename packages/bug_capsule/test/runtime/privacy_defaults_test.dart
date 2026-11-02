import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';

/// Bodies carry customer data: production builds don't record them unless the
/// app says so (BC-ENT-017).
void main() {
  BugCapsuleConfig config(CaptureMode mode, {bool? bodies}) => BugCapsuleConfig(
    appVersion: '1',
    appBuild: '1',
    mode: mode,
    captureNetworkBodies: bodies,
  );

  test('production records no request or response bodies by default', () {
    expect(config(CaptureMode.production).captureNetworkBodies, isFalse);
  });

  test('debug and QA keep recording bodies by default', () {
    expect(config(CaptureMode.debug).captureNetworkBodies, isTrue);
    expect(config(CaptureMode.qa).captureNetworkBodies, isTrue);
  });

  test('an explicit setting wins in every mode', () {
    expect(
      config(CaptureMode.production, bodies: true).captureNetworkBodies,
      isTrue,
    );
    expect(config(CaptureMode.qa, bodies: false).captureNetworkBodies, isFalse);
  });

  test('binary bodies are not kept by default', () {
    expect(BugCapsuleDio().maxBinaryBytes, 0);
    expect(BugCapsuleHttp().maxBinaryBytes, 0);
  });
}
