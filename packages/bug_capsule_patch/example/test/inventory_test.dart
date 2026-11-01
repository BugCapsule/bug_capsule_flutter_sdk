import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:bug_capsule_patch_example/main.dart' as lab;
void main() {
  test('module-only lab matches registered coupon capability hash', () {
    final dir = Directory.systemTemp.createTempSync('lab-inventory-');
    final patch = BugCapsulePatch.open(PatchConfig(storeDir:dir.path,
      projectId:'offline', applicationId:lab.applicationId, environment:lab.environment,
      platform:'flutter_ios', distributionProfile:'development', baseBuildId:lab.baseBuildId,
      installationId:'offline', trustRoots:const [lab.trustAnchor]), modules:[lab.coupon],
      surfaces:lab.labSurfaces, libraryPath:Platform.environment['BCPATCH_HOST_LIB']);
    try {
      expect(patch.available, true, reason:patch.unavailableReason);
      expect(patch.status()['baseCapabilityHash'],
        lab.moduleOnly ? 'sha256:4b37753ff79051b8fa1290db23addc5863f29c16b3c3d9390af5eb613b639b43'
          : 'sha256:da91890d5f675dd883b604b07cdb14ce8aaeee27ae37d4df723c79b6653a1968');
    } finally {patch.close();dir.deleteSync(recursive:true);}
  }, skip:Platform.environment['BCPATCH_HOST_LIB']==null);
}
