import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An integration that decorates the binding's default messenger, so
/// plugins registered on it are covered (the platform channel integration).
abstract interface class MessengerInterceptor {
  bool get interceptDefaultMessenger;
  BinaryMessenger wrapDefaultMessenger(BinaryMessenger inner);
}

/// The binding BugCapsule creates when an integration intercepts the
/// default messenger: a [WidgetsFlutterBinding] whose messenger is wrapped
/// before any plugin can use it.
class BugCapsuleBinding extends WidgetsFlutterBinding {
  BugCapsuleBinding._(this._wrap);

  final BinaryMessenger Function(BinaryMessenger) _wrap;

  @override
  BinaryMessenger createBinaryMessenger() =>
      _wrap(super.createBinaryMessenger());

  /// Creates the binding with [interceptors] around its default messenger,
  /// or returns the existing binding unchanged (the interceptors then
  /// report the late installation themselves).
  static WidgetsBinding ensureInitialized(
    List<MessengerInterceptor> interceptors,
  ) {
    if (interceptors.isEmpty || hasBinding) {
      return WidgetsFlutterBinding.ensureInitialized();
    }
    BugCapsuleBinding._((m) {
      var out = m;
      for (final i in interceptors) {
        out = i.wrapDefaultMessenger(out);
      }
      return out;
    });
    return WidgetsBinding.instance;
  }

  /// Whether a binding exists already.
  static bool get hasBinding {
    try {
      WidgetsBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }
}
