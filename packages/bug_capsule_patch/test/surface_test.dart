import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('falls back to the bundled layout without a runtime', (tester) async {
    final patch = BugCapsulePatch.open(
      const PatchConfig(storeDir: '/tmp/x', projectId: 'p', applicationId: 'a', environment: 'e', platform: 'flutter_android', distributionProfile: 'development', baseBuildId: 'b', installationId: 'i', trustRoots: []),
      modules: const [],
      libraryPath: '/nonexistent/libbcpatch',
    );
    expect(patch.available, isFalse);
    await tester.pumpWidget(MaterialApp(home: PatchSurfaceView(patch: patch, id: 's', actions: const {}, bundled: const Text('bundled'))));
    expect(find.text('bundled'), findsOneWidget);
  });
}
