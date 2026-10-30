import 'package:bug_capsule/src/core/core.dart';
import 'package:bug_capsule/src/runtime/monitoring/sessions.dart';
import 'package:flutter_test/flutter_test.dart';

const _patched = CapsulePatchIdentity(
  baseBuildId: 'base-1',
  patchSetDigest: 'sha256:patched',
  engineAbi: 1,
  hostAbiHash: 'sha256:host',
);
const _bare = CapsulePatchIdentity(
  baseBuildId: 'base-1',
  patchSetDigest: null,
  engineAbi: 1,
  hostAbiHash: 'sha256:host',
);

void main() {
  late List<Map<String, Object?>> sent;
  Map<String, Object?>? saved;

  SessionTracker tracker(CapsulePatchIdentity? identity) => SessionTracker(
    release: 'app@1+1',
    environment: 'staging',
    distinctId: () => 'install',
    send: sent.add,
    persist: (state) => saved = state,
    patch: () => identity,
  );

  setUp(() {
    sent = [];
    saved = null;
  });

  test('every update carries the patch, starting with the first', () {
    tracker(_patched)
      ..start()
      ..end();

    expect(sent, hasLength(2));
    for (final payload in sent) {
      expect(payload['patchBaseBuildId'], 'base-1');
      expect(payload['patchSetDigest'], 'sha256:patched');
    }
  });

  test('the bare base reports its build with no digest, the rollout control', () {
    tracker(_bare).start();

    expect(sent.single['patchBaseBuildId'], 'base-1');
    expect(sent.single.containsKey('patchSetDigest'), isFalse);
  });

  test('no patch runtime sends neither field', () {
    tracker(null).start();

    expect(sent.single.containsKey('patchBaseBuildId'), isFalse);
    expect(sent.single.containsKey('patchSetDigest'), isFalse);
  });

  test('a recovered session reports the patch it ran, not the current one', () {
    tracker(_patched).start();
    final previous = saved!;
    sent.clear();

    final update = tracker(_bare).recover(previous, crashed: true)!;

    expect(update['status'], 'crashed');
    expect(update['patchBaseBuildId'], 'base-1');
    expect(update['patchSetDigest'], 'sha256:patched');
  });

  test('a session saved before identity existed claims no patch', () {
    tracker(null).start();
    final previous = saved!;

    final update = tracker(_patched).recover(previous, crashed: true)!;

    expect(update.containsKey('patchBaseBuildId'), isFalse);
    expect(update.containsKey('patchSetDigest'), isFalse);
  });
}
