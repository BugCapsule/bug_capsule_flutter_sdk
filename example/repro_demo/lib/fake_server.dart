import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Simulated shop backend running inside the app.
///
/// It behaves like a real production backend from the app's point of view:
/// latency varies and data differs between calls. That nondeterminism is
/// what makes the planted bugs "cannot reproduce" — and what Repro records.
class FakeShopServer implements HttpClientAdapter {
  FakeShopServer({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const _catalog = [
    {'sku': 'mug', 'name': 'Flutter mug', 'price': 12.5},
    {'sku': 'tee', 'name': 'Dash T-shirt', 'price': 24.0},
    {'sku': 'cap', 'name': 'Repro cap', 'price': 18.0},
    {'sku': 'sticker', 'name': 'Sticker pack', 'price': 4.0},
    {'sku': 'hoodie', 'name': 'Widget hoodie', 'price': 55.0},
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    final path = options.uri.path;
    switch (path) {
      case '/api/cart':
        await _latency(80, 400);
        // 1 in 4 carts contains a discontinued item whose price is null.
        final items = [
          for (final p in (_catalog.toList()..shuffle(_random)).take(1 + _random.nextInt(3)))
            {...p, 'qty': 1 + _random.nextInt(2)},
          if (_random.nextInt(4) == 0)
            {'sku': 'legacy-pin', 'name': 'Legacy pin (discontinued)', 'price': null, 'qty': 1},
        ];
        return _json({'cartId': 'c_${_random.nextInt(99999)}', 'items': items});
      case '/api/checkout':
        await _latency(150, 500);
        return _json({'orderId': 'o_${_random.nextInt(99999)}', 'status': 'paid'});
      case '/api/profile':
        await _latency(100, 600);
        return _json({'name': 'Sam', 'tier': ['gold', 'silver'][_random.nextInt(2)]});
      case '/api/recommendations':
        await _latency(250, 900);
        return _json({
          'items': [for (final p in (_catalog.toList()..shuffle(_random)).take(3)) p['name']],
        });
      case '/api/orders':
        await _latency(100, 400);
        // 1 in 4 times the order list is still being computed.
        if (_random.nextInt(4) == 0) return _json({'status': 'processing'}, status: 202);
        return _json({
          'orders': [
            for (var i = 0; i < 1 + _random.nextInt(4); i++)
              {'id': 'o_${1000 + i}', 'total': 10 + _random.nextInt(90), 'status': 'delivered'},
          ],
        });
      default:
        return _json({'error': 'not found'}, status: 404);
    }
  }

  Future<void> _latency(int minMs, int maxMs) =>
      Future.delayed(Duration(milliseconds: minMs + _random.nextInt(maxMs - minMs)));

  ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
