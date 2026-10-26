import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/material.dart';

/// A quote feed on a loopback WebSocket. Every few quotes the server
/// restarts; after a reconnect it repeats the last quote it sent, and
/// sometimes that repeat arrives together with the next one.
class QuoteServer {
  QuoteServer._(this._server);

  static const port = 47311;
  static QuoteServer? _instance;

  final HttpServer _server;
  int _seq = 0;

  static Uri get url => Uri.parse('ws://127.0.0.1:$port/v1/quotes?ts=0');

  static Future<void> ensureStarted() async {
    if (_instance != null) return;
    try {
      _instance = QuoteServer._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, port),
      ).._serve();
    } on SocketException {
      // Already running (hot restart) or replaying without a server.
    }
  }

  void _serve() {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
      if (_seq > 0) {
        // Resume: repeat the last quote, then continue.
        socket
          ..add(_quote(_seq))
          ..add(_quote(++_seq));
      }
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        socket.add(_quote(++_seq));
      }
      await socket.close(4001, 'restarting');
    });
  }

  static String _quote(int seq) =>
      jsonEncode({'symbol': 'BUGC', 'seq': seq, 'price': 40 + (seq % 7) * 0.5});
}

/// Planted bug: a repeated quote after a reconnect looks like time going
/// backwards and throws. The fix is to ignore quotes already seen.
class QuoteBook extends ChangeNotifier {
  int lastSeq = 0;
  double? price;

  void onQuote(Object? message) {
    final quote = jsonDecode(message! as String) as Map<String, Object?>;
    final seq = quote['seq']! as int;
    if (seq <= lastSeq) {
      throw StateError('Quote went stale (#$seq after #$lastSeq)');
    }
    lastSeq = seq;
    price = (quote['price']! as num).toDouble();
    notifyListeners();
  }
}

class QuotesScreen extends StatefulWidget {
  const QuotesScreen({super.key, required this.sockets});

  final BugCapsuleWebSocket sockets;

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> {
  final QuoteBook _book = QuoteBook();
  StreamSubscription<Object?>? _subscription;
  int _connections = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    await QuoteServer.ensureStarted();
    if (_disposed || _connections >= 4) return;
    _connections++;
    final channel = widget.sockets.connect(QuoteServer.url);
    try {
      await channel.ready;
    } catch (_) {
      return;
    }
    if (mounted) setState(() {});
    _subscription = channel.stream.listen(
      _book.onQuote,
      // The server restarted: reconnect.
      onDone: () => unawaited(_connect()),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live quotes')),
      body: Center(
        child: ListenableBuilder(
          listenable: _book,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _book.price == null
                    ? 'Waiting for quotes…'
                    : 'BUGC ${_book.price!.toStringAsFixed(2)}',
                key: const Key('quotes.price'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text('quote #${_book.lastSeq} · connection $_connections'),
            ],
          ),
        ),
      ),
    );
  }
}
