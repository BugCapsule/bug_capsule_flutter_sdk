/// WebSocket integration for BugCapsule (capsule-v2 `websocket`).
///
/// Opt-in: open connections through [BugCapsuleWebSocket.connect] (a
/// `web_socket_channel` [WebSocketChannel]) or [BugCapsuleWebSocket.connectIo]
/// (a `dart:io` [io.WebSocket]) instead of the library constructors.
///
/// ```dart
/// final sockets = BugCapsuleWebSocket();
/// BugCapsule.init(integrations: [sockets, ...], ...);
///
/// final channel = sockets.connect(Uri.parse('wss://quotes.example.com/v1'));
/// await channel.ready;
/// channel.sink.add('{"op":"subscribe","symbol":"ACME"}');
/// channel.stream.listen(onQuote);
/// ```
///
/// Capture records the connection, the negotiated protocol, every text
/// frame the app sends and receives, connection and stream errors, and who
/// closed the connection with which code. Binary frames are recorded as
/// metadata (their size) unless `captureBinary: true`. Replay never
/// connects: it serves the recorded connection in memory with the recorded
/// timing, compares what the app sends, and fails unrecorded connections.
///
/// Connections made with other constructors, Socket.IO and other protocols
/// on top of WebSockets are not covered. Reconnect policy stays the app's:
/// each recorded attempt is replayed in order. Ping/pong frames are not
/// recorded.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../runtime/runtime.dart';

class BugCapsuleWebSocket extends InteractionIntegration {
  BugCapsuleWebSocket({
    this.ignoreQuery = const {'_', 'ts', 'timestamp', 'nonce', 'cachebust'},
    this.metadataOnly,
    super.captureBinary,
    super.redactedReplayable,
  });

  /// Query parameters left out of the connection key (they change on every
  /// connect).
  final Set<String> ignoreQuery;

  /// Connections whose frames are recorded as sizes only (e.g. a chat
  /// socket carrying personal messages). They cannot be replayed faithfully.
  final bool Function(Uri url)? metadataOnly;

  @override
  String get name => 'web_socket';

  @override
  String get adapter => 'bug_capsule.web_socket_channel';

  @override
  String get kind => DependencyKinds.websocket;

  @override
  List<String> get operations => const ['connect', 'send', 'close'];

  @override
  Map<String, String> get tested => const {'web_socket_channel': '3.0.3'};

  final OccurrenceCounter _occurrences = OccurrenceCounter();
  final Map<String, int> _finished = {};
  final Map<String, _RecordingTransport> _open = {};
  int _nextConn = 0;

  /// Opens a [WebSocketChannel] to [url]: recorded while capturing, served
  /// from the capsule while replaying, plain `WebSocketChannel.connect`
  /// otherwise.
  WebSocketChannel connect(Uri url, {Iterable<String>? protocols}) {
    final replay = replayInteractions;
    if (replay != null || replayingWithoutRecording) {
      return _ChannelFacade(_ReplayTransport(this, replay, url));
    }
    if (!capturing) return WebSocketChannel.connect(url, protocols: protocols);
    final transport = _record(url, protocols, () {
      final channel = WebSocketChannel.connect(url, protocols: protocols);
      return _ChannelInner(channel);
    });
    return transport == null
        ? WebSocketChannel.connect(url, protocols: protocols)
        : _ChannelFacade(transport);
  }

  /// Opens a `dart:io` [io.WebSocket] to [url] (not available on the web);
  /// recorded and replayed like [connect].
  Future<io.WebSocket> connectIo(
    String url, {
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
  }) async {
    final uri = Uri.parse(url);
    final replay = replayInteractions;
    if (replay != null || replayingWithoutRecording) {
      final transport = _ReplayTransport(this, replay, uri, dartIo: true);
      await transport.ready;
      return _IoFacade(transport);
    }
    Future<io.WebSocket> real() =>
        io.WebSocket.connect(url, protocols: protocols, headers: headers);
    if (!capturing) return real();
    final ready = Completer<io.WebSocket>();
    final transport = _record(uri, protocols, () => _IoInner(real()));
    if (transport == null) return real();
    unawaited(
      transport.ready.then(
        (_) => ready.complete(_IoFacade(transport)),
        onError: ready.completeError,
      ),
    );
    return ready.future;
  }

  /// The connection key: the redacted URL without ignored query
  /// parameters, query sorted.
  String keyFor(Uri url) {
    final redacted = session!.redactor.redactUri(url);
    final params = redacted.queryParametersAll;
    final query = [
      for (final name in params.keys.toList()..sort())
        if (!ignoreQuery.contains(name))
          for (final v in params[name]!) '$name=$v',
    ];
    final port = redacted.hasPort ? ':${redacted.port}' : '';
    return '${redacted.scheme}://${redacted.host}$port'
        '${redacted.path.isEmpty ? '/' : redacted.path}'
        '${query.isEmpty ? '' : '?${query.join('&')}'}';
  }

  _RecordingTransport? _record(
    Uri url,
    Iterable<String>? protocols,
    _Inner Function() open,
  ) {
    if (!host!.acquire()) {
      stats.gap(DependencyGaps.connectionsLimit);
      return null;
    }
    final key = keyFor(url);
    final conn = 'ws${_nextConn++}';
    recordInteraction(InteractionTypes.wsConnect, {
      'conn': conn,
      'url': session!.redactor.redactUrl(url.toString()),
      'key': key,
      'occurrence': _occurrences.next(key),
      'attempt': _finished[key] ?? 0,
      if (protocols != null && protocols.isNotEmpty)
        'protocols': protocols.toList(),
    });
    final transport = _RecordingTransport(
      this,
      conn,
      key,
      metadataOnly?.call(url) ?? false,
    );
    _open[conn] = transport;
    try {
      transport.attach(open());
    } catch (e) {
      transport.connectFailed(e);
      rethrow;
    }
    return transport;
  }

  void _closed(_RecordingTransport t) {
    if (_open.remove(t.conn) == null) return;
    _finished[t.key] = (_finished[t.key] ?? 0) + 1;
    host?.release();
  }

  @override
  List<Map<String, Object?>> openInteractions() => [
    for (final conn in _open.keys) {'type': 'ws', 'id': conn},
  ];

  InteractionPayload _payload(Object? data, {required bool metadata}) {
    final kind = data is String ? 'text' : 'binary';
    final bytes = data is String
        ? utf8.encode(data).length
        : data is List<int>
        ? data.length
        : 0;
    if (metadata || !(session?.captureNetworkBodies ?? true)) {
      return InteractionPayload(
        mode: metadata ? PayloadMode.metadata : PayloadMode.omitted,
        replayable: false,
        bytes: bytes,
        kind: kind,
      );
    }
    final value = data is List<int> && data is! Uint8List
        ? Uint8List.fromList(data)
        : data;
    return encoder.encode(value, kind: kind);
  }
}

// ------------------------------------------------------------- transports

/// What both facades need from a connection.
abstract class _Transport {
  Future<void> get ready;
  Stream<dynamic> get stream;
  String? get protocol;
  int? get closeCode;
  String? get closeReason;
  bool get isOpen;
  bool get isClosed;
  void send(Object? data);
  Future<void> close([int? code, String? reason]);
  Future<void> get done;
}

/// The real connection under a recording transport.
abstract class _Inner {
  Future<void> get ready;
  Stream<dynamic> get stream;
  String? get protocol;
  int? get closeCode;
  String? get closeReason;
  void send(Object? data);
  Future<void> close(int? code, String? reason);
}

class _ChannelInner implements _Inner {
  _ChannelInner(this.channel);

  final WebSocketChannel channel;

  @override
  Future<void> get ready => channel.ready;
  @override
  Stream<dynamic> get stream => channel.stream;
  @override
  String? get protocol => channel.protocol;
  @override
  int? get closeCode => channel.closeCode;
  @override
  String? get closeReason => channel.closeReason;
  @override
  void send(Object? data) => channel.sink.add(data);
  @override
  Future<void> close(int? code, String? reason) async =>
      channel.sink.close(code, reason);
}

class _IoInner implements _Inner {
  _IoInner(this.socket) {
    socket.then((s) => _socket = s, onError: (Object _) {});
  }

  final Future<io.WebSocket> socket;
  io.WebSocket? _socket;
  final StreamController<dynamic> _relay = StreamController();
  bool _relaying = false;

  @override
  Future<void> get ready => socket;
  @override
  Stream<dynamic> get stream {
    if (!_relaying) {
      _relaying = true;
      socket.then(
        (s) => _relay.addStream(s).whenComplete(_relay.close),
        onError: (Object e, StackTrace st) {
          _relay
            ..addError(e, st)
            ..close();
        },
      );
    }
    return _relay.stream;
  }

  @override
  String? get protocol => _socket?.protocol;
  @override
  int? get closeCode => _socket?.closeCode;
  @override
  String? get closeReason => _socket?.closeReason;
  @override
  void send(Object? data) {
    final s = _socket;
    if (s == null) throw StateError('WebSocket is not connected');
    s.add(data);
  }

  @override
  Future<void> close(int? code, String? reason) async {
    final s = _socket ?? await socket;
    await s.close(code, reason);
  }
}

class _RecordingTransport implements _Transport {
  _RecordingTransport(this.owner, this.conn, this.key, this.metadataOnly);

  final BugCapsuleWebSocket owner;
  final String conn;
  final String key;
  final bool metadataOnly;
  late final _Inner _inner;
  final Completer<void> _done = Completer();
  int _sent = 0;
  int _received = 0;
  bool _opened = false;
  bool _connectError = false;
  bool _clientClosed = false;
  bool _ended = false;
  StreamSubscription<dynamic>? _sub;

  /// The inner stream is read from the start, so a connection the app
  /// never listens to (a failed connect) or stops listening to still ends
  /// and frees its capture slot.
  late final StreamController<dynamic> _relay = StreamController(
    onPause: () => _sub?.pause(),
    onResume: () => _sub?.resume(),
    onCancel: () {
      final sub = _sub;
      _sub = null;
      _end(cancelled: true);
      return sub?.cancel();
    },
  );

  void _record(String type, Map<String, Object?> data) {
    // Remote config may disable the adapter while the connection is open.
    if (!owner.capturing) return;
    try {
      owner.recordInteraction(type, {'conn': conn, ...data});
    } catch (_) {
      owner.stats.gap(DependencyGaps.captureFailed, type);
    }
  }

  static Map<String, Object?> _error(Object e) => {
    'type': e.runtimeType.toString(),
    'message': '$e',
  };

  void attach(_Inner inner) {
    _inner = inner;
    inner.ready.then((_) {
      _opened = true;
      _record(InteractionTypes.wsOpen, {
        if (inner.protocol != null) 'protocol': inner.protocol,
      });
    }, onError: connectFailed);
    _sub = inner.stream.listen(
      (data) {
        _record(InteractionTypes.wsMessage, {
          'index': _received++,
          'payload': owner._payload(data, metadata: metadataOnly).toJson(),
        });
        _relay.add(data);
      },
      onError: (Object error, StackTrace st) {
        if (_opened) {
          _record(InteractionTypes.wsError, {
            'phase': 'stream',
            'error': _error(error),
          });
        } else {
          connectFailed(error);
        }
        _relay.addError(error, st);
      },
      onDone: () {
        _sub = null;
        _end();
        _relay.close();
      },
    );
  }

  void connectFailed(Object e) {
    if (_connectError || _opened) return;
    _connectError = true;
    _record(InteractionTypes.wsError, {'phase': 'connect', 'error': _error(e)});
  }

  void _end({bool cancelled = false}) {
    if (_ended) return;
    _ended = true;
    _record(InteractionTypes.wsClose, {
      'initiator': cancelled
          ? 'client'
          : _clientClosed || _inner.closeCode == null
          ? 'unknown'
          : 'server',
      if (cancelled) 'cancelled': true,
      if (_inner.closeCode != null) 'code': _inner.closeCode,
      if (_inner.closeReason != null && _inner.closeReason!.isNotEmpty)
        'reason': _inner.closeReason,
    });
    owner._closed(this);
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get ready => _inner.ready;

  @override
  Stream<dynamic> get stream => _relay.stream;

  @override
  String? get protocol => _inner.protocol;
  @override
  int? get closeCode => _inner.closeCode;
  @override
  String? get closeReason => _inner.closeReason;
  @override
  bool get isOpen => _opened && !_ended && !_clientClosed;
  @override
  bool get isClosed => _ended;

  @override
  void send(Object? data) {
    _record(InteractionTypes.wsSend, {
      'index': _sent++,
      'payload': owner._payload(data, metadata: metadataOnly).toJson(),
    });
    try {
      _inner.send(data);
    } catch (e) {
      _record(InteractionTypes.wsError, {'phase': 'send', 'error': _error(e)});
      rethrow;
    }
  }

  @override
  Future<void> close([int? code, String? reason]) {
    if (!_clientClosed) {
      _clientClosed = true;
      _record(InteractionTypes.wsClose, {
        'initiator': 'client',
        'code': ?code,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
    }
    return _inner.close(code, reason).whenComplete(() {
      // The close handshake is over even if nobody reads the stream.
      if (_relay.hasListener) return;
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
      _end();
    });
  }

  @override
  Future<void> get done => _done.future;
}

/// A connection served from the capsule: nothing leaves the device. With
/// no [replay] (the capsule has no WebSocket recording) every connection is
/// unrecorded.
class _ReplayTransport implements _Transport {
  _ReplayTransport(this.owner, this.replay, Uri url, {this.dartIo = false}) {
    final key = owner.keyFor(url);
    final recorded = replay?.take(
      owner.dependencyId,
      InteractionTypes.wsConnect,
      key,
    );
    if (recorded == null) {
      owner.diverge('ws.unrecorded', 'connect $key');
      final error = WebSocketChannelException(
        'BugCapsule replay: no recorded connection to $key',
      );
      _ready.completeError(error);
      _ready.future.ignore();
      _controller
        ..addError(error)
        ..close();
      _scope = null;
      _markDone();
      return;
    }
    _scope = recorded.scope;
    replay!.bind(recorded.scope, _deliver);
  }

  final BugCapsuleWebSocket owner;
  final ReplayInteractions? replay;

  /// A `dart:io` socket: recorded errors are rebuilt as `dart:io` types.
  final bool dartIo;
  late final String? _scope;
  final Completer<void> _ready = Completer();
  final Completer<void> _done = Completer();

  void _markDone() {
    if (!_done.isCompleted) _done.complete();
  }

  Object _errorOf(Map<String, Object?> data) {
    final error = (data['error'] as Map?) ?? const {};
    final message = '${error['message'] ?? 'recorded error'}';
    if (dartIo) {
      switch (error['type']) {
        case 'SocketException':
          return io.SocketException(message);
        case 'HandshakeException':
          return io.HandshakeException(message);
        case 'WebSocketException':
          return io.WebSocketException(message);
      }
    }
    return WebSocketChannelException(message);
  }

  final StreamController<dynamic> _controller = StreamController();
  String? _protocol;
  int? _closeCode;
  String? _closeReason;
  bool _opened = false;
  bool _clientClosed = false;

  void _deliver(RecordedInteraction r) {
    switch (r.type) {
      case InteractionTypes.wsOpen:
        _opened = true;
        _protocol = r.data['protocol'] as String?;
        if (!_ready.isCompleted) _ready.complete();
      case InteractionTypes.wsMessage:
        final payload = r.payload('payload');
        if (payload == null || !payload.replayable) {
          owner.diverge(
            'ws.noPayload',
            '${r.data['conn']} message ${r.data['index']} '
                '(${payload?.mode.name ?? 'missing'})',
          );
          return;
        }
        final value = payload.decoded;
        _controller.add(value is List<int> ? Uint8List.fromList(value) : value);
      case InteractionTypes.wsError:
        final error = _errorOf(r.data);
        if (r.data['phase'] == 'connect' && !_ready.isCompleted) {
          _ready.completeError(error);
          _ready.future.ignore();
        }
        _controller.addError(error);
      case InteractionTypes.wsClose:
        _closeCode = r.data['code'] as int?;
        _closeReason = r.data['reason'] as String?;
        if (!_ready.isCompleted) {
          _ready.completeError(
            WebSocketChannelException('connection closed before it opened'),
          );
          _ready.future.ignore();
        }
        _finish();
    }
  }

  void _finish() {
    final scope = _scope;
    if (scope != null) replay?.unbind(scope);
    if (!_ready.isCompleted) {
      _ready.completeError(
        WebSocketChannelException('connection closed before it opened'),
      );
      _ready.future.ignore();
    }
    if (!_controller.isClosed) _controller.close();
    _markDone();
  }

  @override
  Future<void> get ready => _ready.future;
  @override
  Stream<dynamic> get stream => _controller.stream;
  @override
  String? get protocol => _protocol;
  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;
  @override
  bool get isOpen => _opened && !_controller.isClosed && !_clientClosed;
  @override
  bool get isClosed => _controller.isClosed;

  @override
  void send(Object? data) {
    if (_clientClosed || _controller.isClosed) {
      throw StateError('Cannot add event after closing.');
    }
    final scope = _scope;
    final replay = this.replay;
    if (scope == null || replay == null) return;
    final recorded = replay.takeNext(scope, const {InteractionTypes.wsSend});
    if (recorded == null) {
      owner.diverge('ws.unrecorded', '${scope.substring(3)}: extra send');
      return;
    }
    final expected = recorded.payload('payload');
    final live = InteractionPayload(
      mode: PayloadMode.full,
      replayable: true,
      value: owner.encoder.keyInput(
        data is List<int> && data is! Uint8List
            ? Uint8List.fromList(data)
            : data,
      ),
      bytes: data is String
          ? utf8.encode(data).length
          : data is List<int>
          ? data.length
          : null,
      kind: data is String ? 'text' : 'binary',
    );
    if (expected != null && !expected.sameAs(live)) {
      owner.diverge(
        'ws.mismatch',
        '${scope.substring(3)} send ${recorded.data['index']} differs from the recording',
      );
    }
  }

  @override
  Future<void> close([int? code, String? reason]) {
    if (!_clientClosed) {
      _clientClosed = true;
      final scope = _scope;
      final replay = this.replay;
      if (scope != null && replay != null) {
        final matched = replay.takeNext(scope, const {
          InteractionTypes.wsClose,
        });
        // Nothing more reaches the app after it closed, except the
        // server's close answering a recorded client close; anything else
        // still scheduled is reported as unused.
        replay.drop(
          scope,
          keep: matched == null ? const {} : const {InteractionTypes.wsClose},
        );
        if (matched == null || replay.scheduledIn(scope) == 0) {
          _closeCode = code;
          _closeReason = reason;
          _finish();
        }
      } else {
        _finish();
      }
    }
    return done;
  }

  @override
  Future<void> get done => _done.future;
}

// ---------------------------------------------------------------- facades

class _ChannelFacade
    with StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _ChannelFacade(this._t);

  final _Transport _t;
  late final _Sink _sink = _Sink(_t);

  @override
  Future<void> get ready => _t.ready;
  @override
  Stream<dynamic> get stream => _t.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  String? get protocol => _t.protocol;
  @override
  int? get closeCode => _t.closeCode;
  @override
  String? get closeReason => _t.closeReason;
}

class _Sink implements WebSocketSink {
  _Sink(this._t);

  final _Transport _t;

  @override
  void add(dynamic data) => _t.send(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // Like web_socket_channel: an error closes the connection.
    unawaited(_t.close());
  }

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _t.close(closeCode, closeReason);

  @override
  Future<void> get done => _t.done;
}

class _IoFacade extends Stream<dynamic> implements io.WebSocket {
  _IoFacade(this._t);

  final _Transport _t;

  @override
  Duration? pingInterval;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _t.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int get readyState => _t.isClosed
      ? io.WebSocket.closed
      : _t.isOpen
      ? io.WebSocket.open
      : io.WebSocket.closing;

  @override
  String get extensions => '';
  @override
  String? get protocol => _t.protocol;
  @override
  int? get closeCode => _t.closeCode;
  @override
  String? get closeReason => _t.closeReason;

  @override
  void add(dynamic data) => _t.send(data);

  @override
  void addUtf8Text(List<int> bytes) => _t.send(utf8.decode(bytes));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      unawaited(_t.close());

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<dynamic> close([int? code, String? reason]) => _t.close(code, reason);

  @override
  Future<dynamic> get done => _t.done;
}
