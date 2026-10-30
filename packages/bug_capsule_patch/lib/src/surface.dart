import 'dart:convert';

import 'package:flutter/material.dart';

import 'runtime.dart';

/// What the installed binary can render for a surface. Part of the base
/// capability hash: a patch must target exactly this.
final class PatchSurfaceContract {
  const PatchSurfaceContract({
    required this.id,
    required this.components,
    required this.actions,
    this.requiredActions = const [],
    this.assets = const [],
  });

  final String id;
  final List<String> components;
  final List<String> actions;

  /// Actions a layout must keep. A layout dropping one is refused.
  final List<String> requiredActions;
  final List<String> assets;

  Map<String, Object?> toJson() => {
    'id': id,
    'components': components,
    'actions': actions,
    'requiredActions': requiredActions,
    'assets': assets,
  };
}

/// Renders the patched layout of a registered surface with shipped widgets,
/// or [bundled] when this generation has none. Actions run the app's own
/// handlers; [images] resolves `image` nodes the app ships. If any referenced
/// image is missing, the whole bundled surface is rendered.
class PatchSurfaceView extends StatelessWidget {
  const PatchSurfaceView({
    super.key,
    required this.patch,
    required this.id,
    required this.actions,
    required this.bundled,
    this.images = const {},
    this.onTextChanged,
  });

  final BugCapsulePatch patch;
  final String id;
  final Map<String, VoidCallback> actions;
  final Map<String, ImageProvider> images;
  final void Function(String action, String id, String value)? onTextChanged;
  final Widget bundled;

  @override
  Widget build(BuildContext context) {
    final doc = patch.surface(id);
    if (doc == null) return bundled;
    final root =
        (jsonDecode(utf8.decode(doc)) as Map<String, Object?>)['root']!
            as Map<String, Object?>;
    var nodes = 0;
    bool canRender(Map<String, Object?> node, int depth) {
      if (++nodes > 512 || depth > 16) return false;
      if (node['type'] == 'image' && !images.containsKey(node['asset'])) {
        return false;
      }
      return ((node['children'] as List<Object?>?) ?? const <Object?>[]).every(
        (child) => canRender(child! as Map<String, Object?>, depth + 1),
      );
    }

    return canRender(root, 0) ? _node(context, root) : bundled;
  }

  Widget _node(BuildContext context, Map<String, Object?> n) {
    final kids = [
      for (final c in (n['children'] as List<Object?>?) ?? const <Object?>[])
        _node(context, c! as Map<String, Object?>),
    ];
    final spacing = ((n['spacing'] as int?) ?? 0).toDouble();
    switch (n['type']) {
      case 'text':
        final theme = Theme.of(context).textTheme;
        final style = switch (n['style']) {
          'title' => theme.titleLarge,
          'caption' => theme.bodySmall,
          _ => theme.bodyMedium,
        };
        return Text(n['text']! as String, style: style);
      case 'image':
        final image = images[n['asset']];
        final label = n['label']! as String;
        return Image(image: image!, semanticLabel: label);
      case 'spacer':
        return SizedBox.square(dimension: (n['size']! as int).toDouble());
      case 'button':
        return FilledButton(
          onPressed: actions[n['action']],
          child: Text(n['label']! as String),
        );
      case 'text_field':
        final action = n['action']! as String;
        return TextField(
          decoration: InputDecoration(labelText: n['label']! as String),
          onChanged: (v) => onTextChanged?.call(action, n['id']! as String, v),
        );
      case 'row':
        return Row(spacing: spacing, children: kids);
      case 'list':
        return ListView(shrinkWrap: true, children: kids);
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: spacing,
          children: kids,
        );
    }
  }
}
