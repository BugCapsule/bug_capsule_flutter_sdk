import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:bug_capsule_patch/src/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared vectors, through the real FFI. BCPATCH_HOST_LIB names a host build.
void main() {
  final path = Platform.environment['BCPATCH_HOST_LIB'];
  final skip = path == null ? 'set BCPATCH_HOST_LIB' : null;

  test('eval vectors agree on output, fuel and memory', () {
    final native = Native.load(path)!;
    final cases = jsonDecode(File('test/fixtures/eval.json').readAsStringSync()) as List<Object?>;
    for (final c in cases.cast<Map<String, Object?>>()) {
      final request = '{"input":${jsonEncode(c['input'])},"output":${jsonEncode(c['output'])},"value":${c['value']}}';
      try {
        final r = jsonDecode(utf8.decode(native.call(nullptr, opLocalEval, a: base64Decode(c['module']! as String), b: utf8.encode(request)))) as Map<String, Object?>;
        expect(c['code'], isNull, reason: c['name'] as String?);
        expect(r['output'], c['expected'], reason: c['name'] as String?);
        expect(r['steps'], c['steps'], reason: c['name'] as String?);
        expect(r['memory'], c['memory'], reason: c['name'] as String?);
      } on NativeError catch (e) {
        expect(e.code, c['code'], reason: c['name'] as String?);
      }
    }
    expect(cases.length, greaterThanOrEqualTo(40));
  }, skip: skip);

  test('artifact and channel vectors agree', () {
    final native = Native.load(path)!;
    final wire = jsonDecode(File('test/fixtures/wire.json').readAsStringSync()) as Map<String, Object?>;
    final t = wire['target']! as Map<String, Object?>;
    Pointer<Void> open() {
      final dir = Directory.systemTemp.createTempSync('bcv');
      return native.open(utf8.encode(jsonEncode({...t, 'storeDir': dir.path, 'installationId': 'i', 'trustRoots': [wire['trustRoot']]})));
    }

    for (final a in (wire['artifacts']! as List<Object?>).cast<Map<String, Object?>>()) {
      final e = open();
      try {
        native.call(e, opStage, a: base64Decode(a['bundle']! as String));
        expect(a['code'], isNull, reason: a['name'] as String?);
      } on NativeError catch (x) {
        expect(x.code, a['code'], reason: a['name'] as String?);
      }
      native.close(e);
    }
    for (final c in (wire['channels']! as List<Object?>).cast<Map<String, Object?>>()) {
      final e = open();
      try {
        native.call(e, opChannel, a: base64Decode(c['document']! as String), b: base64Decode(c['signature']! as String));
        expect(c['code'], isNull, reason: c['name'] as String?);
      } on NativeError catch (x) {
        expect(x.code, c['code'], reason: c['name'] as String?);
      }
      native.close(e);
    }
  }, skip: skip);
}
