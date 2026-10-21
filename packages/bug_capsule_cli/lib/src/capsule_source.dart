import 'dart:io';

import 'package:bug_capsule_core/bug_capsule_core.dart';

import 'backend_client.dart';

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// A capsule loaded from a file, a backend id, or a share link.
class LoadedCapsule {
  LoadedCapsule(this.bytes, this.capsule, {this.serverId, this.origin = ''});

  final List<int> bytes;
  final Capsule capsule;

  /// Backend capsule id when the capsule came from (or is known to) the
  /// backend; replay results are reported there.
  final String? serverId;
  final String origin;
}

Future<LoadedCapsule> loadCapsule(String ref, {String? serverId}) async {
  final file = File(ref);
  if (file.existsSync()) {
    final bytes = await file.readAsBytes();
    return LoadedCapsule(bytes, CapsuleCodec.decode(bytes), serverId: serverId, origin: file.path);
  }
  if (ref.startsWith('http://') || ref.startsWith('https://')) {
    final creds = Credentials.load() ?? Credentials(url: ref);
    final bytes = await BackendClient(creds).downloadShared(Uri.parse(ref));
    return LoadedCapsule(bytes, CapsuleCodec.decode(bytes), serverId: serverId, origin: ref);
  }
  if (_uuid.hasMatch(ref)) {
    final creds = Credentials.load();
    if (creds == null) {
      throw StateError('"$ref" looks like a capsule id but no backend is configured; run `bugcapsule login`');
    }
    final bytes = await BackendClient(creds).downloadCapsule(ref);
    return LoadedCapsule(bytes, CapsuleCodec.decode(bytes), serverId: ref, origin: 'backend');
  }
  throw StateError('no such file, capsule id or share link: $ref');
}
