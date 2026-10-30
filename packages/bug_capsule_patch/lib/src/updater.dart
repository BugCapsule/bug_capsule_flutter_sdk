import 'dart:typed_data';

import 'native.dart';
import 'runtime.dart';

/// Signed channel metadata as delivered, kept as the exact received bytes.
final class SignedChannel {
  const SignedChannel(this.document, this.signature, {this.etag});
  final Uint8List document;
  final Uint8List signature;
  final String? etag;
}

/// How an app reaches its delivery endpoint. TLS, tokens and retries live
/// here; the runtime treats everything that comes back as untrusted.
abstract interface class PatchTransport {
  /// Null means nothing changed since [etag].
  Future<SignedChannel?> fetchChannel({String? etag});
  Future<Uint8List> fetchArtifact(String digest);
  Future<void> postReceipts(Map<String, Object?> batch);
}

enum PatchUpdateState { upToDate, restartRequired, notInCohort, quarantined, failed }

final class PatchUpdateResult {
  const PatchUpdateResult(this.state, {this.artifactDigest, this.reason});
  final PatchUpdateState state;
  final String? artifactDigest;
  final String? reason;
}

/// Check, download, verify, stage. Never restarts the app and never changes
/// the running generation. Failures are returned, not thrown, and leave the
/// next launch as it was. Concurrent calls join the one in flight.
final class PatchUpdater {
  PatchUpdater(this.patch, this.transport);

  final BugCapsulePatch patch;
  final PatchTransport transport;
  String? _etag;
  Future<PatchUpdateResult>? _running;

  Future<PatchUpdateResult> checkForUpdate() => _running ??= _check().whenComplete(() => _running = null);

  Future<PatchUpdateResult> _check() async {
    try {
      final channel = await transport.fetchChannel(etag: _etag);
      if (channel == null) return const PatchUpdateResult(PatchUpdateState.upToDate);
      final result = await _act(patch.applyChannel(channel.document, channel.signature));
      // Only after the download and staging worked: a 304 must not end retries.
      _etag = channel.etag;
      return result;
    } on NativeError catch (e) {
      return PatchUpdateResult(PatchUpdateState.failed, reason: e.code);
    } on Object catch (e) {
      return PatchUpdateResult(PatchUpdateState.failed, reason: 'transport: $e');
    }
  }

  Future<PatchUpdateResult> _act(Map<String, Object?> d) async {
    final digest = d['artifactDigest'] as String?;
    switch (d['action']) {
      case 'download':
        final bundle = await transport.fetchArtifact(digest!);
        final staged = patch.stage(bundle);
        return PatchUpdateResult(PatchUpdateState.restartRequired, artifactDigest: staged['artifactDigest'] as String?);
      case 'restart_required':
        final target = d['target'] as String?;
        return PatchUpdateResult(PatchUpdateState.restartRequired, artifactDigest: target == 'base' ? null : target);
      default:
        return switch (d['reason']) {
          'not_in_cohort' => const PatchUpdateResult(PatchUpdateState.notInCohort),
          'quarantined' => PatchUpdateResult(PatchUpdateState.quarantined, artifactDigest: digest),
          _ => const PatchUpdateResult(PatchUpdateState.upToDate),
        };
    }
  }

  /// Uploads local receipts and acknowledges them only after the server took
  /// them. An offline device keeps them for later. Returns how many were sent.
  Future<int> flushReceipts() async {
    final batch = patch.receipts();
    final items = (batch['receipts']! as List<Object?>).cast<Map<String, Object?>>();
    if (items.isEmpty) return 0;
    await transport.postReceipts({...batch, 'status': patch.status()});
    patch.ackReceipts(items.last['seq']! as int);
    return items.length;
  }
}
