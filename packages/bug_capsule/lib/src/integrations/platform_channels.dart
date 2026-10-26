/// Flutter platform channel integration for BugCapsule (capsule-v2
/// `platform.channel`).
///
/// Records the traffic of allowlisted MethodChannels, EventChannels and
/// BasicMessageChannels in both directions and, during replay, answers the
/// app from the capsule instead of the native plugin.
///
/// ```dart
/// final channels = BugCapsulePlatformChannels(channels: [
///   PlatformChannel.method('plugins.example.com/battery'),
///   PlatformChannel.event('plugins.example.com/charging'),
/// ]);
/// BugCapsule.init(integrations: [channels, ...], ...);
/// ```
///
/// Plugins that use the default messenger are covered when BugCapsule
/// creates the binding: call `BugCapsule.init` first in `main`, before
/// `WidgetsFlutterBinding.ensureInitialized()` and before any plugin is used.
/// EventChannels need this even for channels you create: Flutter sends their
/// `listen` and `cancel` calls through the default messenger whatever
/// messenger the channel was given.
/// If the binding already exists, capture records a `channel.late` gap and
/// replay a `dependency.late` divergence instead of pretending to cover
/// plugins it cannot see. Channels you create yourself can pass
/// [BugCapsulePlatformChannels.messenger] explicitly.
///
/// Not covered: channels that are not listed, framework channels
/// (`flutter/*`, text input, accessibility, rendering), background isolates
/// (`BackgroundIsolateBinaryMessenger`), additional engines, plugins with
/// their own messenger instances, FFI, platform views, textures and native
/// work that never crosses a channel. Pigeon and other custom codecs decode
/// to objects BugCapsule cannot serialize: such payloads are recorded as
/// metadata with a `codec.unsupported` gap until an adapter exists.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../runtime/runtime.dart';

enum PlatformChannelKind { method, event, message }

/// One allowlisted channel and the codec its messages use.
class PlatformChannel {
  /// A MethodChannel (`StandardMethodCodec` by default).
  const PlatformChannel.method(
    this.name, {
    MethodCodec codec = const StandardMethodCodec(),
    this.codecId,
  }) : kind = PlatformChannelKind.method,
       methodCodec = codec,
       messageCodec = null;

  /// An EventChannel: `listen`/`cancel` calls and the events the platform
  /// sends back on the same channel.
  const PlatformChannel.event(
    this.name, {
    MethodCodec codec = const StandardMethodCodec(),
    this.codecId,
  }) : kind = PlatformChannelKind.event,
       methodCodec = codec,
       messageCodec = null;

  /// A BasicMessageChannel (`StandardMessageCodec` by default).
  const PlatformChannel.message(
    this.name, {
    MessageCodec<Object?> codec = const StandardMessageCodec(),
    this.codecId,
  }) : kind = PlatformChannelKind.message,
       methodCodec = null,
       messageCodec = codec;

  final String name;
  final PlatformChannelKind kind;
  final MethodCodec? methodCodec;
  final MessageCodec<Object?>? messageCodec;

  /// Identifies a custom codec in the capsule; known codecs have ids.
  final String? codecId;

  String get codec {
    if (codecId != null) return codecId!;
    final c = methodCodec ?? messageCodec;
    return switch (c) {
      JSONMethodCodec() => 'json.method',
      StandardMethodCodec() when c.runtimeType == StandardMethodCodec =>
        'standard.method',
      JSONMessageCodec() => 'json.message',
      StringCodec() => 'string.message',
      BinaryCodec() => 'binary.message',
      StandardMessageCodec() when c.runtimeType == StandardMessageCodec =>
        'standard.message',
      _ => 'custom:${c.runtimeType}',
    };
  }

  bool get knownCodec => !codec.startsWith('custom:');
}

class BugCapsulePlatformChannels extends InteractionIntegration
    implements MessengerInterceptor {
  BugCapsulePlatformChannels({
    required List<PlatformChannel> channels,
    this.interceptDefaultMessenger = true,
    super.captureBinary,
    super.redactedReplayable,
  }) : _channels = {
         for (final c in channels)
           if (!_reserved(c.name)) c.name: c,
       } {
    assert(
      channels.every((c) => !_reserved(c.name)),
      'framework and BugCapsule channels (flutter/*, bugcapsule/*) cannot be allowlisted',
    );
  }

  /// Wrap the binding's default messenger so registered plugins are
  /// covered (needs `BugCapsule.init` to create the binding).
  @override
  final bool interceptDefaultMessenger;
  final Map<String, PlatformChannel> _channels;

  static bool _reserved(String name) =>
      name.startsWith('flutter/') || name.startsWith('bugcapsule/');

  @override
  String get name => 'platform_channels';

  @override
  String get adapter => 'bug_capsule.platform_channels';

  @override
  String get kind => DependencyKinds.platformChannel;

  @override
  List<String> get operations => const ['call', 'listen', 'message'];

  final OccurrenceCounter _occurrences = OccurrenceCounter();
  final Map<String, int> _generations = {};
  final Map<String, String> _captureSubs = {};
  final Map<String, int> _eventIndex = {};
  int _nextCall = 0;
  int _nextSub = 0;
  bool _late = false;

  /// Handlers the app registered for allowlisted channels during replay
  /// (the platform side is replaced, so they are not forwarded).
  final Map<String, MessageHandler> _replayHandlers = {};
  final Map<String, RecordedInteraction> _replaySubs = {};

  /// [inner] (the binding's default messenger by default) with this
  /// integration's recording and replay. Pass it to channels you create:
  /// `MethodChannel('my/channel', const StandardMethodCodec(), channels.messenger())`.
  BinaryMessenger messenger([BinaryMessenger? inner]) {
    final base = inner ?? ServicesBinding.instance.defaultBinaryMessenger;
    if (base is _ChannelMessenger && base.owner == this) return base;
    return _ChannelMessenger(this, base);
  }

  /// The decorator for the binding's default messenger.
  @override
  BinaryMessenger wrapDefaultMessenger(BinaryMessenger inner) =>
      _ChannelMessenger(this, inner);

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    await super.setUp(session);
    if (!interceptDefaultMessenger || _channels.isEmpty) return;
    BinaryMessenger? current;
    try {
      current = ServicesBinding.instance.defaultBinaryMessenger;
    } catch (_) {
      current = null;
    }
    final covered =
        BugCapsuleBinding.isInstalled(this) ||
        (current is _ChannelMessenger && current.owner == this);
    if (covered) return;
    _late = true;
    const detail =
        'the binding existed before BugCapsule.init; plugins using the '
        'default messenger are not covered';
    if (session.replay != null) {
      diverge('dependency.late', '$adapter: $detail');
    } else {
      stats.gap(DependencyGaps.channelLate, detail);
    }
  }

  void _endSub(String sub) {
    if (_eventIndex.remove(sub) != null) host?.release();
  }

  @override
  List<Map<String, Object?>> openInteractions() => [
    for (final sub in _captureSubs.values) {'type': 'platform.sub', 'id': sub},
  ];

  /// Whether the default messenger is covered (false after a late setup).
  bool get coversDefaultMessenger => interceptDefaultMessenger && !_late;

  PlatformChannel? _spec(String channel) => _channels[channel];

  String _key(String channel, String? method, Object? args) =>
      interactionKey(channel, method, encoder.keyInput(args));

  Map<String, Object?> _payload(PlatformChannel spec, Object? value) {
    if (!spec.knownCodec &&
        !TypedValue.isReplayable(TypedValue.encode(value))) {
      stats.gap(
        DependencyGaps.codecUnsupported,
        '${spec.name} (${spec.codec})',
      );
      return const InteractionPayload(
        mode: PayloadMode.metadata,
        replayable: false,
      ).toJson();
    }
    return encoder.encode(value).toJson();
  }
}

/// Channel decorator: delegates everything that is not allowlisted, records
/// allowlisted traffic while capturing and serves it while replaying.
class _ChannelMessenger implements BinaryMessenger {
  _ChannelMessenger(this.owner, this.inner);

  final BugCapsulePlatformChannels owner;
  final BinaryMessenger inner;

  // Replay state lives on the integration: an EventChannel sends
  // `listen` through the default messenger even when it was given another
  // one, so several decorators share it.
  Map<String, MessageHandler> get _replayHandlers => owner._replayHandlers;
  Map<String, RecordedInteraction> get _replaySubs => owner._replaySubs;

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
    // ignore: deprecated_member_use
  ) => inner.handlePlatformMessage(channel, data, callback);

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    final spec = owner._spec(channel);
    if (spec == null) return inner.send(channel, message);
    final replay = owner.replayInteractions;
    if (replay != null) return _replaySend(replay, spec, message);
    if (owner.replayingWithoutRecording) {
      owner.diverge('platform.unrecorded', '$channel (not in the capsule)');
      return Future.value(
        _errorEnvelope(spec, 'bugcapsule.unrecorded', 'not in the capsule'),
      );
    }
    if (!owner.capturing) return inner.send(channel, message);
    return _captureSend(spec, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    final spec = owner._spec(channel);
    if (spec == null) return inner.setMessageHandler(channel, handler);
    final replay = owner.replayInteractions;
    if (replay != null) {
      _replaySetHandler(replay, spec, handler);
      return;
    }
    // Replaying without a recording: the native side must not call in.
    if (owner.replayingWithoutRecording) return;
    inner.setMessageHandler(
      channel,
      handler == null
          ? null
          : (message) => _captureIncoming(spec, handler, message),
    );
  }

  // ----------------------------------------------------------------- capture

  void _record(String type, Map<String, Object?> data) {
    try {
      owner.recordInteraction(type, data);
    } catch (_) {
      owner.stats.gap(DependencyGaps.captureFailed, type);
    }
  }

  ({String? method, Object? args})? _decodeOutgoing(
    PlatformChannel spec,
    ByteData? message,
  ) {
    try {
      if (spec.kind == PlatformChannelKind.message) {
        return (method: null, args: spec.messageCodec!.decodeMessage(message));
      }
      final call = spec.methodCodec!.decodeMethodCall(message);
      return (method: call.method, args: call.arguments);
    } catch (_) {
      owner.stats.gap(DependencyGaps.codecUnsupported, spec.name);
      return null;
    }
  }

  Future<ByteData?> _captureSend(
    PlatformChannel spec,
    ByteData? message,
  ) async {
    final decoded = _decodeOutgoing(spec, message);
    if (decoded == null) return inner.send(spec.name, message);
    final (:method, :args) = decoded;
    final channel = spec.name;
    if (spec.kind == PlatformChannelKind.event &&
        (method == 'listen' || method == 'cancel')) {
      if (method == 'listen') {
        if (!(owner.host?.acquire() ?? false)) {
          owner.stats.gap(DependencyGaps.connectionsLimit, channel);
          return inner.send(channel, message);
        }
        final sub = 'p${owner._nextSub++}';
        final call = 'c${owner._nextCall++}';
        final key = owner._key(channel, 'listen', args);
        owner._captureSubs[channel] = sub;
        owner._eventIndex[sub] = 0;
        _record(InteractionTypes.platformListen, {
          'channel': channel,
          'codec': spec.codec,
          'sub': sub,
          'call': call,
          'gen': owner._generations[channel] =
              (owner._generations[channel] ?? -1) + 1,
          'args': owner._payload(spec, args),
          'key': key,
          'occurrence': owner._occurrences.next(key),
        });
        // A failed listen is reported by Flutter itself (FlutterError), so
        // its answer is part of what the app saw.
        final reply = await inner.send(channel, message);
        _recordReply(spec, call, reply, missingIsError: true);
        return reply;
      }
      if (owner._captureSubs.remove(channel) case final sub?) {
        owner._endSub(sub);
        _record(InteractionTypes.platformCancel, {
          'channel': channel,
          'sub': sub,
        });
      }
      return inner.send(channel, message);
    }
    final call = 'c${owner._nextCall++}';
    final key = owner._key(channel, method, args);
    _record(InteractionTypes.platformCall, {
      'channel': channel,
      'codec': spec.codec,
      'call': call,
      'dir': 'dart',
      'method': ?method,
      'args': owner._payload(spec, args),
      'key': key,
      'occurrence': owner._occurrences.next(key),
      'isolate': 'root',
    });
    final ByteData? reply;
    try {
      reply = await inner.send(channel, message);
    } catch (e) {
      _record(InteractionTypes.platformError, {
        'channel': channel,
        'call': call,
        'kind': 'exception',
        'message': '$e',
      });
      rethrow;
    }
    _recordReply(spec, call, reply, missingIsError: true);
    return reply;
  }

  /// Records the answer to call [call]: a result, an error envelope, or a
  /// missing handler (a null reply on a method channel).
  void _recordReply(
    PlatformChannel spec,
    String call,
    ByteData? reply, {
    required bool missingIsError,
  }) {
    final channel = spec.name;
    if (spec.kind == PlatformChannelKind.message) {
      Object? value;
      try {
        value = spec.messageCodec!.decodeMessage(reply);
      } catch (_) {
        owner.stats.gap(DependencyGaps.codecUnsupported, channel);
      }
      _record(InteractionTypes.platformResult, {
        'channel': channel,
        'call': call,
        'value': owner._payload(spec, value),
      });
      return;
    }
    if (reply == null && missingIsError) {
      _record(InteractionTypes.platformError, {
        'channel': channel,
        'call': call,
        'kind': 'missing',
      });
      return;
    }
    try {
      final value = spec.methodCodec!.decodeEnvelope(reply!);
      _record(InteractionTypes.platformResult, {
        'channel': channel,
        'call': call,
        'value': owner._payload(spec, value),
      });
    } on PlatformException catch (e) {
      _record(InteractionTypes.platformError, {
        'channel': channel,
        'call': call,
        'kind': 'platform',
        'code': e.code,
        'message': ?e.message,
        if (e.details != null) 'details': owner._payload(spec, e.details),
      });
    } catch (_) {
      owner.stats.gap(DependencyGaps.codecUnsupported, channel);
    }
  }

  Future<ByteData?> _captureIncoming(
    PlatformChannel spec,
    MessageHandler handler,
    ByteData? message,
  ) async {
    if (!owner.capturing) return handler(message);
    final channel = spec.name;
    if (spec.kind == PlatformChannelKind.event) {
      final sub = owner._captureSubs[channel];
      if (sub != null) {
        if (message == null) {
          _record(InteractionTypes.platformDone, {
            'channel': channel,
            'sub': sub,
          });
          owner._captureSubs.remove(channel);
          owner._endSub(sub);
        } else {
          final index = owner._eventIndex[sub] ?? 0;
          owner._eventIndex[sub] = index + 1;
          try {
            final value = spec.methodCodec!.decodeEnvelope(message);
            _record(InteractionTypes.platformEvent, {
              'channel': channel,
              'sub': sub,
              'index': index,
              'value': owner._payload(spec, value),
            });
          } on PlatformException catch (e) {
            _record(InteractionTypes.platformEvent, {
              'channel': channel,
              'sub': sub,
              'index': index,
              'error': {
                'code': e.code,
                'message': ?e.message,
                if (e.details != null)
                  'details': owner._payload(spec, e.details),
              },
            });
          } catch (_) {
            owner.stats.gap(DependencyGaps.codecUnsupported, channel);
          }
        }
      }
      return handler(message);
    }
    final decoded = _decodeOutgoing(spec, message);
    if (decoded == null) return handler(message);
    final (:method, :args) = decoded;
    final call = 'c${owner._nextCall++}';
    final key = owner._key(channel, method, args);
    _record(InteractionTypes.platformCall, {
      'channel': channel,
      'codec': spec.codec,
      'call': call,
      'dir': 'platform',
      'method': ?method,
      'args': owner._payload(spec, args),
      'key': key,
      'occurrence': owner._occurrences.next(key),
      'isolate': 'root',
    });
    final ByteData? reply;
    try {
      reply = await handler(message);
    } catch (e) {
      _record(InteractionTypes.platformError, {
        'channel': channel,
        'call': call,
        'kind': 'exception',
        'message': '$e',
      });
      rethrow;
    }
    _recordReply(spec, call, reply, missingIsError: true);
    return reply;
  }

  // ------------------------------------------------------------------ replay

  ByteData? _errorEnvelope(PlatformChannel spec, String code, String message) =>
      // Message channels have no error envelope; they get a null reply.
      spec.methodCodec?.encodeErrorEnvelope(code: code, message: message);

  Future<ByteData?> _replaySend(
    ReplayInteractions replay,
    PlatformChannel spec,
    ByteData? message,
  ) async {
    final channel = spec.name;
    final decoded = _decodeOutgoing(spec, message);
    if (decoded == null) {
      owner.diverge('platform.unrecorded', '$channel: undecodable message');
      return _errorEnvelope(spec, 'bugcapsule.unrecorded', 'undecodable');
    }
    final (:method, :args) = decoded;
    final dep = owner.dependencyId;
    final codec = spec.methodCodec;
    if (spec.kind == PlatformChannelKind.event &&
        (method == 'listen' || method == 'cancel')) {
      if (method == 'listen') {
        final key = owner._key(channel, 'listen', args);
        final recorded = replay.take(dep, InteractionTypes.platformListen, key);
        if (recorded == null) {
          owner.diverge('platform.unrecorded', '$channel listen');
          return _errorEnvelope(spec, 'bugcapsule.unrecorded', 'listen');
        }
        _replaySubs[channel] = recorded;
        replay.bind(recorded.scope, (e) => _deliverEvent(spec, e));
        final call = recorded.data['call'];
        if (call is String) {
          final reply = Completer<ByteData?>();
          replay.bind('platform.call:$call', (e) {
            replay.unbind('platform.call:$call');
            reply.complete(_encodeReply(spec, e));
          });
          return reply.future;
        }
      } else if (_replaySubs.remove(channel) case final sub?) {
        replay
          ..takeNext(sub.scope, const {InteractionTypes.platformCancel})
          ..unbind(sub.scope);
      }
      return codec!.encodeSuccessEnvelope(null);
    }
    final key = owner._key(channel, method, args);
    final recorded = replay.take(dep, InteractionTypes.platformCall, key);
    if (recorded == null) {
      final mismatch = replay.hasUnconsumed(
        dep,
        InteractionTypes.platformCall,
        '$channel|${method ?? ''}|',
      );
      owner.diverge(
        mismatch ? 'platform.mismatch' : 'platform.unrecorded',
        '$channel ${method ?? 'message'}'
        '${mismatch ? ': arguments differ from the recording' : ''}',
      );
      return _errorEnvelope(
        spec,
        'bugcapsule.unrecorded',
        'BugCapsule replay: no recorded ${method ?? 'message'} on $channel '
            'for these arguments',
      );
    }
    final reply = Completer<ByteData?>();
    replay.bind(recorded.scope, (e) {
      replay.unbind(recorded.scope);
      reply.complete(_encodeReply(spec, e));
    });
    return reply.future;
  }

  /// The bytes the recorded answer [e] decodes to.
  ByteData? _encodeReply(PlatformChannel spec, RecordedInteraction e) {
    final channel = spec.name;
    if (e.type == InteractionTypes.platformError) {
      if (e.data['kind'] == 'missing') return null;
      return spec.methodCodec?.encodeErrorEnvelope(
        code: e.data['code'] as String? ?? 'error',
        message: e.data['message'] as String?,
        details: e.payload('details')?.decoded,
      );
    }
    final payload = e.payload('value');
    if (payload == null || !payload.replayable) {
      owner.diverge('platform.noPayload', '$channel call ${e.data['call']}');
      return _errorEnvelope(
        spec,
        'bugcapsule.noPayload',
        'the recorded result cannot be replayed (${payload?.mode.name})',
      );
    }
    final value = payload.decoded;
    return spec.kind == PlatformChannelKind.message
        ? spec.messageCodec!.encodeMessage(value)
        : spec.methodCodec!.encodeSuccessEnvelope(value);
  }

  void _deliverEvent(PlatformChannel spec, RecordedInteraction e) {
    final handler = _replayHandlers[spec.name];
    if (handler == null) return;
    final codec = spec.methodCodec!;
    ByteData? message;
    switch (e.type) {
      case InteractionTypes.platformDone:
        message = null;
      case InteractionTypes.platformEvent:
        final error = e.data['error'];
        if (error is Map) {
          final details = InteractionPayload.tryParse(error['details']);
          message = codec.encodeErrorEnvelope(
            code: '${error['code']}',
            message: error['message'] as String?,
            details: details?.decoded,
          );
        } else {
          final payload = e.payload('value');
          if (payload == null || !payload.replayable) {
            owner.diverge(
              'platform.noPayload',
              '${spec.name} event ${e.data['index']}',
            );
            return;
          }
          message = codec.encodeSuccessEnvelope(payload.decoded);
        }
      default:
        return;
    }
    unawaited(Future.sync(() => handler(message)));
  }

  void _replaySetHandler(
    ReplayInteractions replay,
    PlatformChannel spec,
    MessageHandler? handler,
  ) {
    final channel = spec.name;
    final scope = 'platform.in:$channel';
    if (handler == null) {
      _replayHandlers.remove(channel);
      replay.unbind(scope);
      return;
    }
    _replayHandlers[channel] = handler;
    if (spec.kind == PlatformChannelKind.event) return;
    replay.bind(scope, (e) => _deliverIncoming(replay, spec, e));
  }

  /// Hands a recorded platform-to-app call to the app's handler and checks
  /// its answer against the recording.
  Future<void> _deliverIncoming(
    ReplayInteractions replay,
    PlatformChannel spec,
    RecordedInteraction e,
  ) async {
    final handler = _replayHandlers[spec.name];
    if (handler == null) return;
    final args = e.payload('args');
    if (args == null || !args.replayable) {
      owner.diverge('platform.noPayload', '${spec.name} ${e.data['method']}');
      return;
    }
    final message = spec.kind == PlatformChannelKind.message
        ? spec.messageCodec!.encodeMessage(args.decoded)
        : spec.methodCodec!.encodeMethodCall(
            MethodCall(e.data['method'] as String, args.decoded),
          );
    ByteData? reply;
    Object? thrown;
    try {
      reply = await handler(message);
    } catch (err) {
      thrown = err;
    }
    final expected = replay.takeNext('platform.call:${e.data['call']}', const {
      InteractionTypes.platformResult,
      InteractionTypes.platformError,
    });
    if (expected == null) return;
    final same = switch (expected.type) {
      InteractionTypes.platformError
          when expected.data['kind'] == 'exception' =>
        thrown != null,
      InteractionTypes.platformError when expected.data['kind'] == 'missing' =>
        thrown == null && reply == null,
      InteractionTypes.platformError =>
        thrown == null && _isError(spec, reply, expected),
      _ => thrown == null && _sameValue(spec, reply, expected),
    };
    if (!same) {
      owner.diverge(
        'platform.mismatch',
        '${spec.name} ${e.data['method'] ?? 'message'}: the app answered differently',
      );
    }
  }

  bool _isError(PlatformChannel spec, ByteData? reply, RecordedInteraction e) {
    if (reply == null) return false;
    try {
      spec.methodCodec!.decodeEnvelope(reply);
      return false;
    } on PlatformException catch (x) {
      return x.code == e.data['code'];
    }
  }

  bool _sameValue(
    PlatformChannel spec,
    ByteData? reply,
    RecordedInteraction e,
  ) {
    final recorded = e.payload('value');
    if (recorded == null || !recorded.replayable) return true;
    try {
      final value = spec.kind == PlatformChannelKind.message
          ? spec.messageCodec!.decodeMessage(reply)
          : spec.methodCodec!.decodeEnvelope(reply!);
      final live = InteractionPayload(
        mode: PayloadMode.full,
        replayable: true,
        value: owner.encoder.keyInput(value),
      );
      return recorded.sameAs(live);
    } catch (_) {
      return false;
    }
  }
}
