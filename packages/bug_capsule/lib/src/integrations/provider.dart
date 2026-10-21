/// Provider / ChangeNotifier / ValueNotifier integration for BugCapsule.
///
/// `ChangeNotifier` has no global observer, so the app hands each notifier
/// it wants recorded to [BugCapsuleNotifiers.track] where it creates it.
/// Tracked notifiers record every notification, snapshot their state into
/// periodic checkpoints, and are restored in replay as soon as they are
/// tracked again.
///
/// ```dart
/// final bugCapsuleNotifiers = BugCapsuleNotifiers();
///
/// ChangeNotifierProvider(
///   create: (_) => bugCapsuleNotifiers.track(
///     CartModel(),
///     id: 'cart',
///     toJson: (cart) => cart.toJson(),
///     restore: (cart, json) => cart.replaceWith(CartModel.fromJson(json)),
///   ),
///   child: ...,
/// );
///
/// final counter = bugCapsuleNotifiers.track(ValueNotifier(0), id: 'counter',
///     toJson: (n) => {'value': n.value}, restore: (n, json) => n.value = json['value'] as int);
/// ```
///
/// Works with anything that is a [Listenable]: `provider`'s
/// `ChangeNotifierProvider` / `ListenableProvider`, plain `ChangeNotifier`s
/// and `ValueNotifier`s held by widgets, and `AnimatedBuilder` /
/// `ListenableBuilder` models.
library;

import 'package:flutter/foundation.dart';
import '../runtime/runtime.dart';

class BugCapsuleNotifiers extends TrackedStateIntegration {
  BugCapsuleNotifiers({super.recordStateData, super.maxStateBytes});

  @override
  String get name => 'notifier';

  /// Records [notifier] as `<id>#<n>` (the n-th notifier tracked with this
  /// [id] in the session) and returns it.
  ///
  /// [toJson] makes its state part of periodic checkpoints and events;
  /// [restore] puts checkpoint state back in replay. Without them, periodic
  /// checkpoints that include this notifier make the capsule partial.
  /// Notifiers tracked before `BugCapsule.init` are not recorded.
  T track<T extends Listenable>(
    T notifier, {
    required String id,
    Object? Function(T notifier)? toJson,
    void Function(T notifier, Map<String, Object?> json)? restore,
  }) =>
      trackObject(
        notifier,
        id: id,
        toJson: toJson,
        restore: restore,
        subscribe: (n, onChange) {
          n.addListener(onChange);
          return onChange;
        },
      );

  @override
  void unsubscribe(Object object, Object subscription) =>
      (object as Listenable).removeListener(subscription as VoidCallback);
}
