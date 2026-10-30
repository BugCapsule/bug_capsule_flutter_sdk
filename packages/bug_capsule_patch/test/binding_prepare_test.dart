import 'dart:async';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';

const config = PatchConfig(storeDir: '/unused', projectId: 'p', applicationId: 'a', environment: 'staging', platform: 'flutter_android', distributionProfile: 'development', baseBuildId: 'base', installationId: 'i', trustRoots: []);

void main() {
  test('concurrent preparations share one resolution and preserve public config', () async {
    var calls = 0;
    final resolved = Completer<PatchConfig>();
    final b = BugCapsulePatchBinding.deferred(() { calls++; return resolved.future; }, modules: []);
    expect(() => b.config, throwsStateError);
    final first = b.prepare();
    final second = b.prepare();
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    resolved.complete(config);
    await Future.wait([first, second]);
    expect(identical(b.config, config), isTrue);
    await b.prepare();
    expect(calls, 1);
  });

  test('failed concurrent resolution may be retried without keeping failed state', () async {
    var calls = 0;
    final failed = Completer<PatchConfig>();
    final b = BugCapsulePatchBinding.deferred(() { calls++; return calls == 1 ? failed.future : Future.value(config); }, modules: []);
    final first = b.prepare();
    final second = b.prepare();
    final checkFirst = expectLater(first, throwsStateError);
    final checkSecond = expectLater(second, throwsStateError);
    failed.completeError(StateError('directory unavailable'));
    await Future.wait([checkFirst, checkSecond]);
    expect(() => b.config, throwsStateError);
    await b.prepare();
    expect(calls, 2);
    expect(identical(b.config, config), isTrue);
  });

  test('synchronous resolver failure is a rejected future and can retry', () async {
    var calls = 0;
    final b = BugCapsulePatchBinding.deferred(() {
      if (++calls == 1) throw StateError('plugin not ready');
      return Future.value(config);
    }, modules: []);
    await expectLater(b.prepare(), throwsStateError);
    await b.prepare();
    expect(calls, 2);
    expect(b.config, same(config));
  });

  test('eager config remains readable and preparation is idempotent', () async {
    final b = BugCapsulePatchBinding(config, modules: []);
    expect(b.config, same(config));
    await Future.wait([b.prepare(), b.prepare()]);
    expect(b.config, same(config));
  });
}
