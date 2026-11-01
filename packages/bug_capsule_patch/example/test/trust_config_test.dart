import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule_patch_example/trust_config.dart';
void main() {
  test('multiple roots preserve order and legacy defaults', () {
    expect(labTrustRoots({'trustRoots':['bcpk.v1.one','bcpk.v1.two']}, 'demo'), ['bcpk.v1.one','bcpk.v1.two']);
    expect(labTrustRoots({'trustRoot':'existing'}, 'demo'), ['existing']);
    expect(labTrustRoots(null, 'demo'), ['demo']);
  });
  test('malformed explicit lists cannot fall back to demo trust', () {
    for (final bad in [null, [], ['invalid'], ['bcpk.v1.one', 2]]) {
      expect(() => labTrustRoots({'trustRoots':bad}, 'demo'), throwsFormatException);
    }
  });
}
