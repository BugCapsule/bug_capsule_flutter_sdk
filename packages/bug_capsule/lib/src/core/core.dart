/// Internal barrel of the pure-Dart core: capsule model (spec v1), flight
/// recorder, codec, redaction and network matching. Shared by the in-app
/// runtime and the `bugcapsule` CLI, so nothing here may import Flutter.
library;

export 'capsule.dart';
export 'capsule_validator.dart';
export 'codec.dart';
export 'event.dart';
export 'failure.dart';
export 'flight_recorder.dart';
export 'http_capture.dart';
export 'idle_compression.dart';
export 'monitoring/envelope.dart';
export 'monitoring/model.dart';
export 'monitoring/stack_trace.dart';
export 'monitoring/trace_headers.dart';
export 'ids.dart';
export 'network.dart';
export 'redaction.dart';
export 'replay_protocol.dart';
export 'verdict.dart';
