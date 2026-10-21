import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../bug_capsule.dart';

/// A ready-made user feedback form (monitoring-v1 §9): optional name and
/// email, a required message. Submitting sends a `feedback` item through
/// `BugCapsule.captureFeedback`, linked to [eventId] when given (e.g.
/// `BugCapsule.lastEventId()` on an error screen).
///
/// Use it inline, or as a sheet with [showBugCapsuleFeedback].
class BugCapsuleFeedbackForm extends StatefulWidget {
  const BugCapsuleFeedbackForm({
    super.key,
    this.eventId,
    this.onSubmitted,
    this.onCancel,
    this.title = 'Report a problem',
    this.messageLabel = 'What happened?',
    this.nameLabel = 'Name',
    this.emailLabel = 'Email',
    this.submitLabel = 'Send',
    this.cancelLabel = 'Cancel',
    this.showName = true,
    this.showEmail = true,
    this.initialName,
    this.initialEmail,
    this.captureCapsule,
  });

  final String? eventId;

  /// Called with the feedback id (null when monitoring is off) after sending.
  final void Function(String? feedbackId)? onSubmitted;
  final VoidCallback? onCancel;
  final String title;
  final String messageLabel;
  final String nameLabel;
  final String emailLabel;
  final String submitLabel;
  final String cancelLabel;
  final bool showName;
  final bool showEmail;
  final String? initialName;
  final String? initialEmail;

  /// Also write a capsule (default: `MonitoringOptions.captureCapsuleWithFeedback`).
  final bool? captureCapsule;

  @override
  State<BugCapsuleFeedbackForm> createState() => _BugCapsuleFeedbackFormState();
}

class _BugCapsuleFeedbackFormState extends State<BugCapsuleFeedbackForm> {
  late final _name = TextEditingController(text: widget.initialName);
  late final _email = TextEditingController(text: widget.initialEmail);
  final _message = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _message.text.trim();
    if (message.isEmpty) {
      setState(() => _error = 'Please describe the problem.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    String? id;
    try {
      id = await BugCapsule.captureFeedback(
        message: message,
        name: _blankToNull(_name.text),
        email: _blankToNull(_email.text),
        eventId: widget.eventId,
        captureCapsule: widget.captureCapsule,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    widget.onSubmitted?.call(id);
  }

  static String? _blankToNull(String s) => s.trim().isEmpty ? null : s.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          if (widget.showName) ...[
            TextField(
              controller: _name,
              enabled: !_sending,
              maxLength: 200,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: widget.nameLabel, counterText: ''),
            ),
            const SizedBox(height: 8),
          ],
          if (widget.showEmail) ...[
            TextField(
              controller: _email,
              enabled: !_sending,
              maxLength: 200,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: widget.emailLabel, counterText: ''),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const ValueKey('bugcapsule.feedback.message'),
            controller: _message,
            enabled: !_sending,
            minLines: 3,
            maxLines: 6,
            maxLength: 5000,
            decoration: InputDecoration(labelText: widget.messageLabel, errorText: _error),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _sending ? null : widget.onCancel, child: Text(widget.cancelLabel)),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending ? null : _submit,
                child: _sending
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.submitLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows [BugCapsuleFeedbackForm] in a modal bottom sheet. Completes with
/// the feedback id, or null when cancelled (or monitoring is off).
Future<String?> showBugCapsuleFeedback(BuildContext context, {String? eventId, bool? captureCapsule}) async {
  String? feedbackId;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
      child: SingleChildScrollView(
        child: BugCapsuleFeedbackForm(
          eventId: eventId,
          captureCapsule: captureCapsule,
          onCancel: () => Navigator.of(sheet).pop(),
          onSubmitted: (id) {
            feedbackId = id;
            Navigator.of(sheet).pop();
          },
        ),
      ),
    ),
  );
  return feedbackId;
}

/// Detects a shake in accelerometer samples (m/s², gravity included): at
/// least [minShakes] samples above [threshold] g within [window], then quiet
/// for [cooldown].
class ShakeDetector {
  ShakeDetector({
    this.threshold = 2.7,
    this.minShakes = 2,
    this.window = const Duration(milliseconds: 500),
    this.cooldown = const Duration(milliseconds: 1500),
  });

  final double threshold;
  final int minShakes;
  final Duration window;
  final Duration cooldown;
  final List<DateTime> _peaks = [];
  DateTime? _last;

  /// True when this sample completes a shake.
  bool add(double x, double y, double z, DateTime at) {
    final g = sqrt(x * x + y * y + z * z) / 9.80665;
    if (g < threshold) return false;
    final last = _last;
    if (last != null && at.difference(last) < cooldown) return false;
    _peaks
      ..removeWhere((p) => at.difference(p) > window)
      ..add(at);
    if (_peaks.length < minShakes) return false;
    _peaks.clear();
    _last = at;
    return true;
  }
}

/// "Shake to report": opens the feedback sheet when the device is shaken.
///
/// BugCapsule has no sensor plugin of its own; pass the accelerometer of the
/// one the app uses, e.g. with `sensors_plus`:
///
/// ```dart
/// BugCapsuleShakeToReport(
///   accelerometer: accelerometerEventStream().map((e) => [e.x, e.y, e.z]),
///   navigatorKey: navigatorKey,  // when placed above the Navigator (MaterialApp.builder)
///   child: child,
/// )
/// ```
class BugCapsuleShakeToReport extends StatefulWidget {
  const BugCapsuleShakeToReport({
    super.key,
    required this.accelerometer,
    required this.child,
    this.navigatorKey,
    this.onShake,
    this.enabled = true,
  });

  /// `[x, y, z]` samples in m/s².
  final Stream<List<double>> accelerometer;
  final Widget child;

  /// Where to show the sheet when this widget is above the app's Navigator.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Replaces opening the sheet.
  final VoidCallback? onShake;
  final bool enabled;

  @override
  State<BugCapsuleShakeToReport> createState() => _BugCapsuleShakeToReportState();
}

class _BugCapsuleShakeToReportState extends State<BugCapsuleShakeToReport> {
  final _detector = ShakeDetector();
  StreamSubscription<List<double>>? _sub;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(BugCapsuleShakeToReport old) {
    super.didUpdateWidget(old);
    if (old.accelerometer != widget.accelerometer || old.enabled != widget.enabled) _listen();
  }

  void _listen() {
    unawaited(_sub?.cancel());
    _sub = widget.enabled ? widget.accelerometer.listen(_onSample, onError: (Object _) {}) : null;
  }

  void _onSample(List<double> s) {
    if (s.length < 3 || !_detector.add(s[0], s[1], s[2], DateTime.now())) return;
    final onShake = widget.onShake;
    if (onShake != null) return onShake();
    if (_open) return;
    final target = widget.navigatorKey?.currentContext ?? context;
    if (!target.mounted) return;
    _open = true;
    unawaited(showBugCapsuleFeedback(target, eventId: BugCapsule.lastEventId())
        .whenComplete(() => _open = false));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
