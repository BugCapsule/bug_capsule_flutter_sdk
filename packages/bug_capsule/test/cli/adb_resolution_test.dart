import 'dart:io';
import 'package:test/test.dart';
import 'package:bug_capsule/src/cli/launcher.dart';

void main() {
  test(
    'Flutter launcher finds SDK adb outside PATH and skips missing SDKs',
    () {
      final dir = Directory.systemTemp.createTempSync('adb-resolution-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sdk = Directory('${dir.path}/sdk with spaces')..createSync();
      final name = Platform.isWindows ? 'adb.exe' : 'adb';
      final adb = File('${sdk.path}/platform-tools/$name')
        ..parent.createSync(recursive: true);
      adb.writeAsStringSync('fixture');
      final properties = File('${dir.path}/android/local.properties')
        ..parent.createSync();
      properties.writeAsStringSync('sdk.dir=${sdk.path}\n');
      expect(
        resolveAndroidAdb(
          dir.path,
          environment: {'ANDROID_HOME': '${dir.path}/missing'},
        ),
        adb.path,
      );
      properties.deleteSync();
      expect(
        resolveAndroidAdb(
          dir.path,
          environment: {'ANDROID_SDK_ROOT': sdk.path},
        ),
        adb.path,
      );
      expect(resolveAndroidAdb(dir.path, environment: {}), name);
    },
  );
}
