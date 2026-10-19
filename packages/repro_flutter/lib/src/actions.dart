import 'package:flutter/widgets.dart';

/// Named UI actions and tracked text fields. In semantic replay the engine
/// invokes actions by id; text fields are always restored by id.
class ActionRegistry {
  final Map<String, void Function(Map<String, Object?>? payload)> _actions = {};
  final Map<String, TextEditingController> _text = {};

  /// The latest registration wins: widgets re-register on every build, so
  /// the handler bound to the currently mounted widget is the one invoked.
  void register(String id, void Function(Map<String, Object?>? payload) handler) =>
      _actions[id] = handler;

  bool invoke(String id, Map<String, Object?>? payload) {
    final handler = _actions[id];
    if (handler == null) return false;
    handler(payload);
    return true;
  }

  void trackText(String id, TextEditingController controller) => _text[id] = controller;

  void untrackText(String id, TextEditingController controller) {
    if (identical(_text[id], controller)) _text.remove(id);
  }

  bool setText(String id, String value) {
    final controller = _text[id];
    if (controller == null) return false;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    return true;
  }
}
