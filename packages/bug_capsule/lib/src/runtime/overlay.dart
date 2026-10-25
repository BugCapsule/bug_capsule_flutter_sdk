import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'bug_capsule.dart';

/// QA capture button. Add it through `MaterialApp.builder`:
///
/// ```dart
/// MaterialApp(builder: (context, child) => BugCapsuleOverlay(child: child!))
/// ```
///
/// Shown only in debug/QA mode while recording. Its own touches are not
/// recorded.
class BugCapsuleOverlay extends StatefulWidget {
  const BugCapsuleOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<BugCapsuleOverlay> createState() => _BugCapsuleOverlayState();
}

class _BugCapsuleOverlayState extends State<BugCapsuleOverlay> {
  bool _open = false;
  bool _busy = false;
  CaptureResult? _result;
  String? _error;

  Future<void> _capture() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await BugCapsule.capture(note: 'Captured from QA overlay');
      setState(() => _result = result);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!BugCapsule.overlayEnabled) return widget.child;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        PositionedDirectional(
          end: 12,
          bottom: 96,
          child: Listener(
            onPointerDown: (e) => BugCapsule.suppressPointer(e.pointer),
            child: Material(
              type: MaterialType.transparency,
              child: _open ? _panel(context) : _button(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _button() => Semantics(
    button: true,
    label: 'BugCapsule capture',
    child: GestureDetector(
      onTap: () => setState(() {
        _open = true;
        _result = null;
        _error = null;
      }),
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xE61D4ED8),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(blurRadius: 6, color: Color(0x40000000))],
        ),
        alignment: Alignment.center,
        child: const Text(
          'R',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
    ),
  );

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final upload = result?.upload;
    return Container(
      width: 280,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Color(0x33000000))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('BugCapsule', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          if (result == null)
            Text(
              'Save the last few minutes of this session as a capsule a developer can replay.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            Text(
              'Capsule ${result.capsuleId.substring(0, 8)}',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              'Eligibility: ${result.eligibility.status.name}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              upload == null
                  ? 'Saved on device (no backend configured)'
                  : switch (upload.status) {
                      UploadStatus.uploaded => 'Uploaded ✓',
                      UploadStatus.retryLater => 'Upload pending (will retry)',
                      UploadStatus.rejected =>
                        'Upload rejected: ${upload.message}',
                    },
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _open = false),
                child: const Text('Close'),
              ),
              if (result != null)
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: upload?.serverId ?? result.capsuleId),
                  ),
                  child: const Text('Copy ID'),
                )
              else
                FilledButton(
                  onPressed: _busy ? null : _capture,
                  child: Text(_busy ? 'Saving…' : 'Save capsule'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
