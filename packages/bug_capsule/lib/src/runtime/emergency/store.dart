import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'crypto.dart';

/// What persists of one environment's policies across launches (§5): the
/// last accepted envelope with its ETag and arrival time, and the highest
/// revision ever accepted, which survives a discarded envelope so an older
/// document can never be replayed.
final class EmergencyCacheEntry {
  const EmergencyCacheEntry({
    required this.applicationId,
    required this.highestRevision,
    this.envelope,
    this.etag,
    this.receivedAt,
  });

  final String applicationId;
  final int highestRevision;

  /// The envelope exactly as received; null after it was discarded.
  final Map<String, Object?>? envelope;
  final String? etag;
  final DateTime? receivedAt;

  Map<String, Object?> toJson() => {
    'v': 1,
    'application_id': applicationId,
    'highest_revision': highestRevision,
    'envelope': envelope,
    'etag': etag,
    'received_at': receivedAt?.millisecondsSinceEpoch,
  };

  /// Null for a file this version cannot read.
  static EmergencyCacheEntry? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    final app = json['application_id'];
    final highest = json['highest_revision'];
    final envelope = json['envelope'];
    final etag = json['etag'];
    final received = json['received_at'];
    if (app is! String || highest is! int || highest < 0) return null;
    if (envelope != null && envelope is! Map) return null;
    if (etag != null && etag is! String) return null;
    if (received != null && received is! int) return null;
    return EmergencyCacheEntry(
      applicationId: app,
      highestRevision: highest,
      envelope: (envelope as Map?)?.cast<String, Object?>(),
      etag: etag as String?,
      receivedAt: received == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(received as int, isUtc: true),
    );
  }
}

/// Files under `<SDK storage root>/emergency/`: one policy cache per
/// environment and, separately, the installation id (§7.3). Writes go to a
/// temporary file that is then renamed over the old one.
final class EmergencyStore {
  EmergencyStore._(this.directory);

  final Directory directory;

  static Future<EmergencyStore> open(Directory directory) async {
    await directory.create(recursive: true);
    try {
      await for (final e in directory.list()) {
        if (e is File && e.path.endsWith('.tmp')) await _deleteQuietly(e);
      }
    } on FileSystemException {
      // Nothing to clean.
    }
    return EmergencyStore._(directory);
  }

  // The environment pattern (§1) only allows file-name-safe characters.
  File _cacheFile(String environment) =>
      File('${directory.path}/policies-$environment.json');
  File get _installationFile => File('${directory.path}/installation_id');

  /// Null when there is no cache or it cannot be read.
  Future<EmergencyCacheEntry?> readCache(String environment) async {
    final file = _cacheFile(environment);
    if (!await file.exists()) return null;
    try {
      return EmergencyCacheEntry.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> writeCache(String environment, EmergencyCacheEntry entry) =>
      _writeAtomically(
        _cacheFile(environment),
        utf8.encode(jsonEncode(entry.toJson())),
      );

  static final RegExp _installationId = RegExp(r'^[A-Za-z0-9_-]{22}$');

  /// The persisted installation id, created on first use: 16 random bytes,
  /// base64url (22 characters).
  Future<String> installationId(Random random) async {
    final file = _installationFile;
    try {
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (_installationId.hasMatch(existing)) return existing;
      }
    } on FileSystemException {
      // Unreadable: replaced below.
    }
    final id = newInstallationId(random);
    await _writeAtomically(file, utf8.encode(id));
    return id;
  }
}

String newInstallationId(Random random) =>
    encodeBase64Url([for (var i = 0; i < 16; i++) random.nextInt(256)]);

Future<void> _writeAtomically(File file, List<int> bytes) async {
  final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Already gone.
  }
}
