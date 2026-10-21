/// GetX integration for BugCapsule.
///
/// GetX has no global observer for state changes, so the app hands each
/// controller and `Rx` value it wants recorded to [BugCapsuleGetx.track] /
/// [BugCapsuleGetx.trackRx] where it creates it. Tracked state records every
/// change, is snapshotted into periodic checkpoints, and is restored in
/// replay as soon as it is tracked again.
///
/// ```dart
/// final bugCapsuleGetx = BugCapsuleGetx();
///
/// class CartController extends GetxController {
///   final items = bugCapsuleGetx.trackRx(<CartItem>[].obs, id: 'cart.items',
///       toJson: (items) => {'items': [for (final i in items) i.toJson()]},
///       fromJson: (json) => [for (final i in json['items'] as List) CartItem.fromJson(i as Map<String, Object?>)]);
///   final coupon = bugCapsuleGetx.trackRx(''.obs, id: 'cart.coupon'); // primitives need no serializer
/// }
///
/// // GetBuilder-style controllers (state changed with `update()`):
/// Get.put(bugCapsuleGetx.track(ProfileController(), id: 'profile',
///     toJson: (c) => c.toJson(), restore: (c, json) => c.restoreFrom(json)));
/// ```
library;

import 'dart:async';

import 'package:get/get.dart';
import '../runtime/runtime.dart';

class BugCapsuleGetx extends TrackedStateIntegration {
  BugCapsuleGetx({super.recordStateData, super.maxStateBytes});

  @override
  String get name => 'getx';

  /// Records a `GetBuilder` controller: every `update()` (without ids; GetX
  /// notifies `update([ids])` only to those builders) is a change.
  ///
  /// [toJson] makes its state part of periodic checkpoints and events;
  /// [restore] puts checkpoint state back in replay. Rx fields of the
  /// controller are recorded with [trackRx].
  C track<C extends GetxController>(
    C controller, {
    required String id,
    Object? Function(C controller)? toJson,
    void Function(C controller, Map<String, Object?> json)? restore,
  }) =>
      trackObject(
        controller,
        id: id,
        toJson: toJson,
        restore: restore,
        subscribe: (c, onChange) => c.addListener(onChange),
      );

  /// Records an `Rx` value (`.obs`, `RxList`, `RxMap`, `RxSet`, ...): every
  /// emitted value is a change, and replay sets `value` from the checkpoint.
  ///
  /// [toJson] / [fromJson] default to `{'value': value}`, which suits
  /// `int`, `double`, `String`, `bool` and lists or maps of them; give them
  /// for anything else.
  R trackRx<R extends RxObjectMixin<V>, V>(
    R rx, {
    required String id,
    Object? Function(V value)? toJson,
    V Function(Map<String, Object?> json)? fromJson,
  }) {
    final encode = toJson ?? (V value) => {'value': value};
    final decode = fromJson ?? (Map<String, Object?> json) => json['value'] as V;
    return trackObject(
      rx,
      id: id,
      toJson: (r) => encode(r.value),
      restore: (r, json) => r.value = decode(json),
      subscribe: (r, onChange) => r.listen((_) => onChange()),
    );
  }

  @override
  void unsubscribe(Object object, Object subscription) => switch (subscription) {
        StreamSubscription<Object?>() => unawaited(subscription.cancel()),
        final void Function() dispose => dispose(),
        _ => null,
      };
}
