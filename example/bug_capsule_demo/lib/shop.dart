import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------------- models

class CartItem {
  const CartItem({required this.sku, required this.name, required this.price, required this.qty});

  factory CartItem.fromJson(Map<String, Object?> j) => CartItem(
        sku: j['sku'] as String,
        name: j['name'] as String,
        price: (j['price'] as num?)?.toDouble(),
        qty: j['qty'] as int,
      );

  final String sku;
  final String name;
  final double? price;
  final int qty;

  Map<String, Object?> toJson() => {'sku': sku, 'name': name, 'price': price, 'qty': qty};
}

enum CartStatus { loading, ready, checkingOut, paid, error }

class CartState {
  const CartState({
    this.status = CartStatus.loading,
    this.cartId,
    this.items = const [],
    this.coupon,
    this.orderId,
    this.message,
  });

  factory CartState.fromJson(Map<String, Object?> j) => CartState(
        status: CartStatus.values.byName(j['status'] as String),
        cartId: j['cartId'] as String?,
        items: [
          for (final i in j['items'] as List) CartItem.fromJson((i as Map).cast<String, Object?>()),
        ],
        coupon: j['coupon'] as String?,
        orderId: j['orderId'] as String?,
        message: j['message'] as String?,
      );

  final CartStatus status;
  final String? cartId;
  final List<CartItem> items;
  final String? coupon;
  final String? orderId;
  final String? message;

  double get subtotal => items.fold(0, (sum, i) => sum + (i.price ?? 0) * i.qty);
  double get discount => switch (coupon) {
        'SAVE10' => subtotal * 0.1,
        // Bug: a fixed discount larger than the cart makes the total negative.
        'SAVE100' => 100,
        _ => 0,
      };
  double get total => subtotal - discount;

  CartState copyWith({
    CartStatus? status,
    String? cartId,
    List<CartItem>? items,
    String? coupon,
    String? orderId,
    String? message,
  }) =>
      CartState(
        status: status ?? this.status,
        cartId: cartId ?? this.cartId,
        items: items ?? this.items,
        coupon: coupon ?? this.coupon,
        orderId: orderId ?? this.orderId,
        message: message ?? this.message,
      );

  Map<String, Object?> toJson() => {
        'status': status.name,
        'cartId': cartId,
        'items': [for (final i in items) i.toJson()],
        'coupon': coupon,
        'orderId': orderId,
        'message': message,
      };
}

// --------------------------------------------------------------------- api

class ShopApi {
  ShopApi(this.dio);
  final Dio dio;

  Future<Map<String, Object?>> getJson(String path) async =>
      ((await dio.get<Map<String, Object?>>(path)).data ?? const {});

  Future<Response<Map<String, Object?>>> get(String path) => dio.get<Map<String, Object?>>(path);

  Future<Map<String, Object?>> postJson(String path, Map<String, Object?> body) async =>
      ((await dio.post<Map<String, Object?>>(path, data: body)).data ?? const {});
}

// -------------------------------------------------------------------- cart

sealed class CartEvent {
  const CartEvent();
}

class CartLoaded extends CartEvent {
  const CartLoaded();
}

class CouponApplied extends CartEvent {
  const CouponApplied(this.code);
  final String code;
}

class CheckoutPressed extends CartEvent {
  const CheckoutPressed();
}

class CartBloc extends Bloc<CartEvent, CartState> {
  CartBloc(this._api) : super(const CartState()) {
    on<CartLoaded>(_onLoad);
    on<CouponApplied>(_onCoupon);
    on<CheckoutPressed>(_onCheckout);
  }

  final ShopApi _api;
  static const cacheKey = 'cart_cache';

  Future<void> _onLoad(CartLoaded event, Emitter<CartState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      // Bug: v0.9 stored the cart as a JSON list; v1.0 expects an object.
      // Only devices upgraded from v0.9 crash here.
      final restored = CartState.fromJson((jsonDecode(cached) as Map).cast<String, Object?>());
      emit(restored.copyWith(status: CartStatus.loading));
    }
    final json = await _api.getJson('/api/cart');
    final next = CartState(
      status: CartStatus.ready,
      cartId: json['cartId'] as String?,
      items: [
        for (final i in json['items'] as List) CartItem.fromJson((i as Map).cast<String, Object?>()),
      ],
    );
    await prefs.setString(cacheKey, jsonEncode(next.toJson()));
    emit(next);
  }

  void _onCoupon(CouponApplied event, Emitter<CartState> emit) {
    final next = state.copyWith(coupon: event.code.trim().toUpperCase());
    BugCapsule.check('cart_total_non_negative', next.total >= 0,
        'total ${next.total} with coupon ${next.coupon}');
    emit(next);
  }

  Future<void> _onCheckout(CheckoutPressed event, Emitter<CartState> emit) async {
    emit(state.copyWith(status: CartStatus.checkingOut));
    // Bug: discontinued items have a null price; `!` crashes checkout.
    final amount = state.items.fold<double>(0, (sum, i) => sum + i.price! * i.qty) - state.discount;
    final result = await _api.postJson('/api/checkout', {
      'cart_id': state.cartId,
      'amount': amount,
      'timestamp': clock.now().millisecondsSinceEpoch,
      'nonce': BugCapsule.random.nextInt(1 << 30),
    });
    emit(state.copyWith(status: CartStatus.paid, orderId: result['orderId'] as String?));
  }
}

// -------------------------------------------------------------------- home

class HomeState {
  const HomeState({this.loading = false, this.profileName, this.tier, this.picks = const [], this.banner});

  factory HomeState.fromJson(Map<String, Object?> j) => HomeState(
        loading: j['loading'] as bool? ?? false,
        profileName: j['profileName'] as String?,
        tier: j['tier'] as String?,
        picks: [for (final p in (j['picks'] as List?) ?? const []) '$p'],
        banner: j['banner'] as String?,
      );

  final bool loading;
  final String? profileName;
  final String? tier;
  final List<String> picks;
  final String? banner;

  Map<String, Object?> toJson() =>
      {'loading': loading, 'profileName': profileName, 'tier': tier, 'picks': picks, 'banner': banner};
}

class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._api) : super(const HomeState());

  final ShopApi _api;

  Future<void> refresh() async {
    emit(const HomeState(loading: true));
    String? tier;
    String? name;
    final profile = _api.getJson('/api/profile').then((json) {
      tier = json['tier'] as String?;
      name = json['name'] as String?;
    });
    final picks = _api.getJson('/api/recommendations').then((json) {
      final items = [for (final i in json['items'] as List) '$i'];
      // Bug: assumes the profile always arrives first. When the
      // recommendations response wins the race, `tier!` throws.
      emit(HomeState(
        loading: true,
        picks: items,
        banner: 'Picks for ${tier!.toUpperCase()} members',
      ));
    });
    await Future.wait([profile, picks]);
    emit(HomeState(profileName: name, tier: tier, picks: state.picks, banner: state.banner));
  }
}

// ------------------------------------------------------------------ orders

class OrdersState {
  const OrdersState({this.loading = true, this.orders = const []});
  final bool loading;
  final List<Map<String, Object?>> orders;
}

class OrdersCubit extends Cubit<OrdersState> {
  OrdersCubit(this._api) : super(const OrdersState());

  final ShopApi _api;
  Timer? _watchdog;

  Future<void> load() async {
    emit(const OrdersState());
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 4), () {
      if (!isClosed && state.loading) {
        BugCapsule.fail('orders_stuck_loading', 'orders still loading after 4s');
      }
    });
    final res = await _api.get('/api/orders');
    // Bug: 202 "processing" is never polled again, so the spinner never ends.
    if (res.statusCode == 202) return;
    final orders = [
      for (final o in (res.data?['orders'] as List?) ?? const []) (o as Map).cast<String, Object?>(),
    ];
    emit(OrdersState(loading: false, orders: orders));
  }

  @override
  Future<void> close() {
    _watchdog?.cancel();
    return super.close();
  }
}
