import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import '../runtime/integration.dart';

/// Explicit diagnostic frames. The provider must mask secrets before returning
/// PNG bytes; return null on sensitive screens. No automatic full-screen capture.
/// Await capture() after rendering and before writing a capsule. Never call from
/// a crash handler. Limits apply to the whole session, including evicted frames.
class ScreenshotIntegration extends BugCapsuleIntegration {
  ScreenshotIntegration({
    this.enabled = false,
    int minIntervalMs = 1000,
    int maxFrames = 20,
    int maxFrameBytes = 262144,
    int maxTotalBytes = 2097152,
    required this.captureRedactedPng,
  }) : minIntervalMs = minIntervalMs.clamp(1000, 3600000),
       maxFrames = maxFrames.clamp(1, 20),
       maxFrameBytes = maxFrameBytes.clamp(1, 262144),
       maxTotalBytes = maxTotalBytes.clamp(1, 2097152);
  final bool enabled;
  final int minIntervalMs, maxFrames, maxFrameBytes, maxTotalBytes;
  final FutureOr<Uint8List?> Function() captureRedactedPng;
  @override
  String get name => 'screenshots';
  BugCapsuleSession? _session;
  int? _last;
  int _count = 0, _bytes = 0;
  bool _busy = false;
  @override
  Future<void> setUp(BugCapsuleSession session) async {
    _session = session;
    _last = null;
    _count = 0;
    _bytes = 0;
  }

  Future<bool> capture() async {
    final s = _session;
    if (!enabled ||
        s == null ||
        !s.isRecording ||
        s.isReplaying ||
        _busy ||
        _count >= maxFrames ||
        _bytes >= maxTotalBytes) {
      return false;
    }
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return false;
    final t = s.now();
    if (_last != null && t - _last! < minIntervalMs) return false;
    _last = t;
    _busy = true;
    try {
      final png = await captureRedactedPng();
      if (png == null ||
          !identical(_session, s) ||
          !s.isRecording ||
          s.isReplaying ||
          png.length < 24 ||
          png.length > maxFrameBytes ||
          _bytes + png.length > maxTotalBytes) {
        return false;
      }
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      for (var i = 0; i < 8; i++) {
        if (png[i] != signature[i]) return false;
      }
      final view = ByteData.sublistView(png);
      final width = view.getUint32(16), height = view.getUint32(20);
      if (width < 1 || height < 1 || width > 2048 || height > 2048) {
        return false;
      }
      String kindAt(int i) => String.fromCharCodes(png.sublist(i + 4, i + 8));
      if (view.getUint32(8) != 13 || kindAt(8) != 'IHDR') return false;
      var pos = 8;
      var hasData = false, ended = false;
      const allowed = [
        'IHDR',
        'PLTE',
        'tRNS',
        'IDAT',
        'IEND',
        'sRGB',
        'gAMA',
        'cHRM',
        'pHYs',
        'sBIT',
      ];
      while (pos + 12 <= png.length) {
        final size = view.getUint32(pos), kind = kindAt(pos);
        if (size > png.length - pos - 12 || !allowed.contains(kind)) {
          return false;
        }
        if (kind == 'IDAT') hasData = true;
        pos += size + 12;
        if (kind == 'IEND') {
          if (size != 0) return false;
          ended = true;
          break;
        }
      }
      if (!hasData || !ended || pos != png.length) return false;
      s.record('screenshot', {
        'schema': 1,
        'mimeType': 'image/png',
        'privacy': 'reviewed',
        'capturedAtT': t,
        'width': width,
        'height': height,
        'base64': base64Encode(png),
      });
      _count++;
      _bytes += png.length;
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Encode an already masked application-owned raster. Caller disposes it.
  /// Works with an offscreen PictureRecorder or a reviewed RepaintBoundary.
  static Future<Uint8List?> pngFromRedactedImage(ui.Image image) async {
    if (image.width > 2048 || image.height > 2048) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > 262144) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
