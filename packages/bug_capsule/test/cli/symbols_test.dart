import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:bug_capsule/src/cli/symbols.dart';
import 'package:test/test.dart';

final buildId = [for (var i = 0; i < 20; i++) 0xa0 + i];

/// A minimal 64-bit little-endian ELF with the build id in a SHT_NOTE section.
Uint8List elf64(List<int> id) {
  final b = BytesBuilder();
  final header = ByteData(64)
    ..setUint32(0, 0x7f454c46)
    ..setUint8(4, 2)
    ..setUint8(5, 1)
    ..setUint8(6, 1)
    ..setUint64(0x28, 104, Endian.little) // e_shoff
    ..setUint16(0x34, 64, Endian.little)
    ..setUint16(0x3a, 64, Endian.little) // e_shentsize
    ..setUint16(0x3c, 2, Endian.little); // e_shnum
  b.add(header.buffer.asUint8List());
  final note = _note(id, Endian.little);
  b.add(note);
  b.add(Uint8List(104 - 64 - note.length));
  b.add(Uint8List(64)); // null section
  final sh = ByteData(64)
    ..setUint32(4, 7, Endian.little) // SHT_NOTE
    ..setUint64(0x18, 64, Endian.little)
    ..setUint64(0x20, note.length, Endian.little);
  b.add(sh.buffer.asUint8List());
  return b.toBytes();
}

/// A minimal 32-bit big-endian ELF with the build id only in a PT_NOTE segment.
Uint8List elf32be(List<int> id) {
  final b = BytesBuilder();
  final header = ByteData(52)
    ..setUint32(0, 0x7f454c46)
    ..setUint8(4, 1)
    ..setUint8(5, 2)
    ..setUint8(6, 1)
    ..setUint32(0x1c, 52) // e_phoff
    ..setUint16(0x2a, 32) // e_phentsize
    ..setUint16(0x2c, 1); // e_phnum
  b.add(header.buffer.asUint8List());
  final note = _note(id, Endian.big);
  final ph = ByteData(32)
    ..setUint32(0, 4) // PT_NOTE
    ..setUint32(4, 84)
    ..setUint32(16, note.length);
  b.add(ph.buffer.asUint8List());
  b.add(note);
  return b.toBytes();
}

/// A minimal thin 64-bit Mach-O with an LC_SEGMENT_64 and an LC_UUID.
Uint8List macho64(List<int> uuid) {
  final header = ByteData(32)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, 2, Endian.little); // ncmds
  final segment = ByteData(72)
    ..setUint32(0, 0x19, Endian.little)
    ..setUint32(4, 72, Endian.little);
  final lcUuid = ByteData(24)
    ..setUint32(0, 0x1b, Endian.little)
    ..setUint32(4, 24, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...segment.buffer.asUint8List(),
    ...lcUuid.buffer.asUint8List(0, 8),
    ...uuid,
  ]);
}

Uint8List _note(List<int> id, Endian e) {
  final head = ByteData(12)
    ..setUint32(0, 4, e)
    ..setUint32(4, id.length, e)
    ..setUint32(8, 3, e);
  return Uint8List.fromList([
    ...head.buffer.asUint8List(),
    ...'GNU\x00'.codeUnits,
    ...id,
  ]);
}

void main() {
  late Directory dir;
  setUp(
    () async =>
        dir = await Directory.systemTemp.createTemp('bugcapsule-symbols-'),
  );
  tearDown(() async => dir.delete(recursive: true));

  test('reads the GNU build id from section headers and program headers', () {
    expect(elfBuildId(elf64(buildId)), buildId);
    expect(elfBuildId(elf32be(buildId)), buildId);
    expect(
      elfBuildId(
        Uint8List.fromList(
          utf8.encode('not an elf file at all, just text padding....'),
        ),
      ),
      isNull,
    );
  });

  test('reads the LC_UUID of Mach-O symbols (iOS / macOS), thin or fat', () {
    final uuid = [for (var i = 0; i < 16; i++) 0x10 + i];
    final thin = macho64(uuid);
    expect(machoUuid(thin), uuid);
    expect(snapshotBuildId(thin), uuid);
    final fat = ByteData(28 + 4)
      ..setUint32(0, 0xcafebabe)
      ..setUint32(4, 1)
      ..setUint32(16, 32) // slice offset
      ..setUint32(20, thin.length);
    expect(
      machoUuid(Uint8List.fromList([...fat.buffer.asUint8List(), ...thin])),
      uuid,
    );
    expect(machoUuid(elf64(buildId)), isNull);
  });

  test(
    'plans one elf upload per .symbols file and the obfuscation map',
    () async {
      File(
        '${dir.path}/app.android-arm64.symbols',
      ).writeAsBytesSync(elf64(buildId));
      File(
        '${dir.path}/app.android-x64.symbols',
      ).writeAsBytesSync(elf32be([1, 2, 3, 4]));
      final map = File('${dir.path}/obfuscation.json')
        ..writeAsStringSync('["MyClass","a"]');
      final plan = await planSymbolUploads(
        splitDebugInfo: dir.path,
        obfuscationMap: map.path,
        obfuscationId: '8F0E2A1C-1234-4ABC-8DEF-0123456789AB',
        release: 'com.shop@1.4.0+52',
      );
      expect(
        [for (final u in plan) u.kind],
        ['elf', 'elf', 'dart_obfuscation'],
      );
      expect(plan[0].query, {
        'debugId': 'a3a2a1a0-a5a4-a7a6-a8a9-aaabacadaeaf',
        'arch': 'arm64',
        'name': 'app.android-arm64.symbols',
      });
      expect(plan[1].query['arch'], 'x86_64');
      expect(plan[1].query['debugId'], '04030201-0000-0000-0000-000000000000');
      expect(plan[2].query, {
        'debugId': '8f0e2a1c-1234-4abc-8def-0123456789ab',
        'release': 'com.shop@1.4.0+52',
      });
    },
  );

  test('refuses unusable input', () async {
    expect(() => planSymbolUploads(), throwsStateError);
    expect(
      () => planSymbolUploads(splitDebugInfo: dir.path),
      throwsStateError,
      reason: 'no .symbols files',
    );
    File('${dir.path}/app.ios-arm64.symbols').writeAsStringSync('not elf');
    expect(
      () => planSymbolUploads(splitDebugInfo: dir.path),
      throwsStateError,
      reason: 'no build id',
    );
    final map = File('${dir.path}/map.json')..writeAsStringSync('[]');
    expect(
      () => planSymbolUploads(obfuscationMap: map.path, obfuscationId: 'nope'),
      throwsStateError,
    );
  });

  test(
    'uploads to POST /v1/debug-files with the secret key, gzip-compressed',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <(String, Uri, String?, String?, String?, List<int>)>[];
      server.listen((req) async {
        final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        requests.add((
          req.method,
          req.uri,
          req.headers.value('authorization'),
          req.headers.value('content-encoding'),
          req.headers.contentType?.mimeType,
          gzip.decode(body),
        ));
        req.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write('{"id":"df1"}');
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = BackendClient(
        Credentials(
          url: 'http://127.0.0.1:${server.port}/',
          secretKey: 'bcs_test',
        ),
      );
      final file = elf64(buildId);
      final res = await client.uploadDebugFile('elf', {
        'debugId': 'a3a2a1a0-a5a4-a7a6-a8a9-aaabacadaeaf',
        'arch': 'arm64',
      }, file);
      expect(res['id'], 'df1');
      final (method, uri, auth, encoding, type, body) = requests.single;
      expect(method, 'POST');
      expect(uri.path, '/v1/debug-files');
      expect(uri.queryParameters, {
        'kind': 'elf',
        'debugId': 'a3a2a1a0-a5a4-a7a6-a8a9-aaabacadaeaf',
        'arch': 'arm64',
      });
      expect(auth, 'Bearer bcs_test');
      expect(encoding, 'gzip');
      expect(type, 'application/octet-stream');
      expect(body, file);
    },
  );
}
