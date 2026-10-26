import 'dart:convert';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAC0lEQVR4nGNgAAMAAAcAAbKGrPQAAAAASUVORK5CYII=',
  );
  test('disabled and replay never call provider', () async {
    var calls = 0;
    final off = ScreenshotIntegration(
      captureRedactedPng: () {
        calls++;
        return png;
      },
    );
    final h = InteractionHarness.capture();
    await h.setUp([off]);
    expect(await off.capture(), false);
    final on = ScreenshotIntegration(
      enabled: true,
      captureRedactedPng: () {
        calls++;
        return png;
      },
    );
    final replay = InteractionHarness.replay([], dependencies: []);
    await replay.setUp([on]);
    expect(await on.capture(), false);
    expect(calls, 0);
  });
  test('records portable PNG and enforces throttle and byte limit', () async {
    final h = InteractionHarness.capture();
    final i = ScreenshotIntegration(
      enabled: true,
      captureRedactedPng: () => png,
    );
    await h.setUp([i]);
    expect(await i.capture(), true);
    expect(await i.capture(), false);
    expect(h.encodedEvents().single.data['base64'], base64Encode(png));
    expect(h.encodedEvents().single.type, 'screenshot');
    final limited = ScreenshotIntegration(
      enabled: true,
      maxFrameBytes: 1,
      captureRedactedPng: () => png,
    );
    await h.setUp([limited]);
    expect(await limited.capture(), false);
  });
  test(
    'private screens, malformed images and failing providers skip safely',
    () async {
      final h = InteractionHarness.capture();
      for (final provider in [
        () => null,
        () => png.sublist(0, 24),
        () => throw StateError('private'),
      ]) {
        final i = ScreenshotIntegration(
          enabled: true,
          captureRedactedPng: provider,
        );
        await h.setUp([i]);
        expect(await i.capture(), false);
      }
      expect(h.events, isEmpty);
    },
  );
}
