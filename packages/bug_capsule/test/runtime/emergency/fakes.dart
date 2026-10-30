import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/emergency/emergency.dart'
    show EmergencyHost;
import 'package:bug_capsule/src/runtime/emergency/transport.dart';

/// A scripted backend: each fetch takes the next answer of [script], or
/// [otherwise] when the script is empty.
class FakeTransport implements EmergencyTransport {
  final List<EmergencyFetchRequest> requests = [];
  final List<FutureOr<EmergencyFetchResult> Function()> script = [];
  EmergencyFetchResult Function() otherwise = () =>
      const EmergencyFetchFailed('network_error', 'offline');
  final List<Map<String, Object?>> receipts = [];
  bool failReceipts = false;

  int get fetches => requests.length;

  void answer(EmergencyFetchResult result) => script.add(() => result);

  @override
  Future<EmergencyFetchResult> fetchPolicies(EmergencyFetchRequest r) async {
    requests.add(r);
    if (script.isNotEmpty) return script.removeAt(0)();
    return otherwise();
  }

  @override
  Future<void> sendReceipt(
    BugCapsuleBackendConfig backend,
    String applicationId,
    Map<String, Object?> receipt,
  ) async {
    receipts.add(receipt);
    if (failReceipts) throw StateError('receipt endpoint down');
  }
}

/// Jitter factor exactly 1.0.
class MidRandom implements Random {
  @override
  double nextDouble() => 0.5;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => max ~/ 2;
}

class FakeHost implements EmergencyHost {
  FakeHost({this.backend, this.appVersion = '2.4.1'});

  @override
  BugCapsuleBackendConfig? backend;
  @override
  bool isReplaying = false;
  @override
  String? appVersion;
  @override
  Directory? storageDirectory;
}
