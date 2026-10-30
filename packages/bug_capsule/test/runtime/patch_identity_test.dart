import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/cli/replay.dart';
import 'package:flutter_test/flutter_test.dart';

const base = 'build-1';
final hash = 'sha256:${'a' * 64}';
final digest = 'sha256:${'b' * 64}';

CapsulePatchIdentity id({String b = base, String? patch, int abi = 1}) => CapsulePatchIdentity(baseBuildId: b, patchSetDigest: patch, engineAbi: abi, hostAbiHash: hash);

CapsuleManifest manifest(CapsulePatchIdentity? patch, {List<CapsuleDependency>? deps}) {
  final doc = <String, Object?>{
    'capsuleId': 'c',
    'createdAt': DateTime.utc(2026).toIso8601String(),
    'mode': CaptureMode.values.first.name,
    'app': {'name': 'a', 'version': '1', 'build': '1', 'bundleId': 'b'},
    'source': <String, Object?>{},
    'sdk': {'name': 's', 'version': '1'},
    'stateSchemaVersion': 1,
    'platform': {'os': 'android', 'osVersion': '1', 'locale': 'en', 'screen': <String, Object?>{'w': 1, 'h': 1, 'dpr': 1}},
    'session': {'id': 's', 'startedAt': DateTime.utc(2026).toIso8601String(), 'wallClockAtAnchorMs': 0, 'durationMs': 0, 'seed': 1},
    'eligibility': {'status': EligibilityStatus.values.first.name},
    'integrations': <String>[],
    'stats': {'eventCount': 0, 'droppedEvents': 0, 'checkpointKind': 'launch'},
    'labels': <String, String>{},
    if (patch != null) 'patch': patch.toJson(),
    if (deps != null) 'dependencies': [for (final d in deps) d.toJson()] else if (patch?.patchSetDigest != null) 'dependencies': [patch!.dependency.toJson()],
  };
  return CapsuleManifest.fromJson(doc);
}

String? check(CapsulePatchIdentity? captured, CapsulePatchIdentity? running, {bool artifact = false, String? expected, bool binding = true, String kind = 'replay', List<CapsuleDependency>? deps}) => patchPreflight(
  manifest: manifest(captured, deps: deps),
  settings: ReplaySettings(patchArtifact: artifact, expectedPatchSetDigest: expected, kind: kind),
  hasBinding: binding,
  running: running,
);

void main() {
  test('identity survives a manifest round trip', () {
    final m = manifest(id(patch: digest));
    expect(m.patch!.patchSetDigest, digest);
    expect(jsonEncode(CapsuleManifest.fromJson(m.toJson()).patch!.toJson()), jsonEncode(m.patch!.toJson()));
  });

  test('a capsule captured on a patch requires the runtime, so it is spec v2', () {
    final dep = manifest(id(patch: digest)).requiredDependencies.single;
    expect(dep.kind, patchRuntimeDependencyKind);
    expect(dep.required, isTrue);
    expect(manifest(id()).requiredDependencies, isEmpty, reason: 'the bare base needs no runtime to replay');
  });

  test('a capsule from before patches still replays', () {
    expect(check(null, null, binding: false), isNull);
    expect(check(null, id()), isNull);
  });

  test('legacy replayers without a binding refuse a patched capsule', () {
    expect(check(id(patch: digest), null, binding: false), startsWith('dependency.unsupported'));
    expect(check(null, null, binding: false, artifact: true, expected: digest), startsWith('dependency.unsupported'));
  });

  test('a missing archived artifact is incompatible, never a base run', () {
    expect(check(id(patch: digest), id()), startsWith('patch.artifact_missing'));
  });

  test('wrong base or ABI is incompatible', () {
    expect(check(id(), id(b: 'other')), startsWith('patch.base'));
    expect(check(id(), id(abi: 2)), startsWith('patch.abi'));
  });

  test('the loaded digest must be the expected digest', () {
    final other = 'sha256:${'c' * 64}';
    expect(check(id(), id(patch: other), artifact: true, expected: digest, kind: 'verify'), startsWith('patch.mismatch'));
    expect(check(id(), id(patch: digest), artifact: true, expected: digest, kind: 'verify'), isNull);
  });

  test('a fix run of a base capsule and a baseline of a patched capsule both pass', () {
    expect(check(id(), id(patch: digest), artifact: true, expected: digest, kind: 'verify'), isNull);
    expect(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest), isNull);
  });

  test('a baseline must run the captured digest; only verify may run a candidate', () {
    final other = 'sha256:${'c' * 64}';
    expect(check(id(patch: digest), id(patch: other), artifact: true, expected: other), startsWith('patch.mismatch'), reason: 'captured A, artifact B');
    expect(check(id(), id(patch: digest), artifact: true, expected: digest), startsWith('patch.mismatch'), reason: 'captured base, artifact B');
    expect(check(null, id(patch: digest), artifact: true, expected: digest), startsWith('patch.mismatch'), reason: 'no identity, artifact B');
    expect(check(id(patch: digest), id(patch: other), artifact: true, expected: other, kind: 'verify'), isNull);
  });

  test('a required patch.runtime is validated, not skipped', () {
    CapsuleDependency dep({String adapter = patchRuntimeAdapter, int schema = 1}) => CapsuleDependency(id: 'patch.runtime', kind: patchRuntimeDependencyKind, adapter: adapter, adapterVersion: '1', schema: schema, required: true, coverage: DependencyCoverage.complete);
    expect(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest, deps: [dep(adapter: 'x.y')]), startsWith('dependency.unsupported'));
    expect(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest, deps: [dep(schema: 2)]), startsWith('dependency.schema'));
    expect(check(null, id(), deps: [dep()]), startsWith('patch.identity_missing'));
    expect(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest, deps: [dep(adapter: patchRuntimeAdapterNative)]), isNull);
  });

  test('a run only counts for an identity every attempt shared', () {
    ReplayReport r(CapsulePatchIdentity? p) => ReplayReport(outcome: ReplayOutcome.notReproduced, attempt: 1, durationMs: 0, strategy: ReplayStrategy.auto, patch: p);
    final same = ReplaySummary(ReplayKind.verify, [r(id(patch: digest)), r(id(patch: digest))], null, requestedAttempts: 2);
    expect(same.patch!.patchSetDigest, digest);
    expect(same.runPayload(device: 'd')['patch'], isNotNull);
    final mixed = ReplaySummary(ReplayKind.verify, [r(id(patch: digest)), r(id())], null, requestedAttempts: 2);
    expect(mixed.patch, isNull);
    expect(mixed.runPayload(device: 'd').containsKey('patch'), isFalse);
  });

  test('the expected digest is read from the artifact manifest', () {
    final m = utf8.encode(jsonEncode({'patchSetDigest': digest}));
    final n = [m.length & 0xff, (m.length >> 8) & 0xff, 0, 0];
    expect(patchSetDigestOf([...'BCPATCH'.codeUnits, 1, ...n, ...m]), digest);
    expect(() => patchSetDigestOf([1, 2, 3]), throwsFormatException);
  });
}
