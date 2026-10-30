import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Signed development fixtures generated with the engine pack tool. They contain
// layout data only, with the exact registration below; no private key is included.
const _imageBundle =
    'QkNQQVRDSAFEBAAAeyJhY3RpdmF0aW9uTW9kZSI6Im5leHRfbGF1bmNoIiwiYXBwbGljYXRpb25JZCI6InRlc3QuaW1hZ2VzIiwiYmFzZUJ1aWxkSWQiOiJiYXNlLWltYWdlcyIsImJhc2VDYXBhYmlsaXR5SGFzaCI6InNoYTI1NjphYzEzMjdiYTEzZTczMGExN2ZmNGI2MjVkMzE0NTc5N2U4MDNkNzNiNzk1YmNhNTAzMjgzMmMwYzQ0NzYyNzQ5IiwiYmxvYnMiOlt7ImRpZ2VzdCI6InNoYTI1Njo0YjQ2YmVkMjJiNWM3NzZjMWJiY2ExZmFjNDI3YzQ3OGJlN2E4OTNlM2Y4NGEwYzY2NGQxOTY3ZTg3N2IyOTliIiwiaWQiOiJ0ZXN0LmltYWdlcyIsImtpbmQiOiJzdXJmYWNlIiwibGVuZ3RoIjoyMDJ9XSwiYnVpbGRSZWNpcGVEaWdlc3QiOiJzaGEyNTY6OWU0MDQ5NDI3NjRmNDNjMmYxM2E0YTQyMWMxYjBhMTNjMDM5NmU2ZDE1MjlhZWFjNzdlZDNkNjM3YTEwNTViYSIsImNvbXBpbGVyRGlnZXN0Ijoic2hhMjU2OmZlNDFlYTY2OGEwYTQ3YmU3NGJlMjdiZDhmNGM4YTBlYzdmMDk2YTg5MTU2OTgyMDJmZWYzOTdkZDdiNjVkYWQiLCJjcmVhdGVkQXQiOjE3OTMzNzg4OTEwODAsImRpc3RyaWJ1dGlvblByb2ZpbGUiOiJkZXZlbG9wbWVudCIsImVuZ2luZUFiaSI6MSwiaG9zdEFiaUhhc2giOiJzaGEyNTY6MzNhNzdmMmM0NTM0YzcwNzEyMDkwMjE0ODRlNzNmNTRhMzI2NDc4NmU2YjA5MzIzZDNhZTg5MDI2YWEyZGZiYyIsImlyVmVyc2lvbiI6MSwia2V5SWQiOiJkZXYtcm9vdC0xIiwibW9kdWxlQ29udHJhY3RzIjpbXSwicGF0Y2hDbGFzcyI6InN1cmZhY2UiLCJwYXRjaElkIjoic3VyZmFjZS1pbWFnZXMiLCJwYXRjaFNlcXVlbmNlIjoxLCJwYXRjaFNldERpZ2VzdCI6InNoYTI1NjphOGE2YzA4MWJiNzk1Y2E3NDYzYWVhNWZiMTBiYjU0YzA5NGU4OGU5OWRlYWYxMzcxNjhhZDcxYTA1ZTBkMDEwIiwicGVybWlzc2lvbnMiOltdLCJwbGF0Zm9ybSI6ImZsdXR0ZXJfYW5kcm9pZCIsInByb2plY3RJZCI6ImRlbW8iLCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2VDb21taXQiOiJkZXY6c2hhMjU2OjM0OWQ1MDQ3NjJjMjY1YWViZWUxYjBiYjBjYTBjMGYwMzNiMDk4MDg4MDFiYjUwOTU5MDMyYjBhM2VlYjBkMmYiLCJzdGF0ZVNjaGVtYVZlcnNpb24iOjB9qr04h2zTPjMZQxvPe+jQZKGOtvAg2s2bN/CeyS6SLusho4Qfrv/P8vdySsaZWyRcz3x7DRbFqKbQLWVkmhyQSXsicm9vdCI6eyJjaGlsZHJlbiI6W3sidGV4dCI6InBhdGNoZWQiLCJ0eXBlIjoidGV4dCJ9LHsiY2hpbGRyZW4iOlt7ImFzc2V0IjoiYnJhbmQubG9nbyIsImxhYmVsIjoiQnJhbmQgbG9nbyIsInR5cGUiOiJpbWFnZSJ9XSwidHlwZSI6Imxpc3QifV0sInR5cGUiOiJjb2x1bW4ifSwic2NoZW1hVmVyc2lvbiI6MSwic3VyZmFjZSI6InRlc3QuaW1hZ2VzIn0=';
const _textBundle =
    'QkNQQVRDSAE+BAAAeyJhY3RpdmF0aW9uTW9kZSI6Im5leHRfbGF1bmNoIiwiYXBwbGljYXRpb25JZCI6InRlc3QuaW1hZ2VzIiwiYmFzZUJ1aWxkSWQiOiJiYXNlLWltYWdlcyIsImJhc2VDYXBhYmlsaXR5SGFzaCI6InNoYTI1NjphYzEzMjdiYTEzZTczMGExN2ZmNGI2MjVkMzE0NTc5N2U4MDNkNzNiNzk1YmNhNTAzMjgzMmMwYzQ0NzYyNzQ5IiwiYmxvYnMiOlt7ImRpZ2VzdCI6InNoYTI1NjpjZjM5YTRhYjIxMWY3Y2U5OTM0M2YwM2E2NGYxMWQ3ZGM5OWNhMThkYjAzYTNlY2IwNmU2YzZmMTM3NmY3MjRiIiwiaWQiOiJ0ZXN0LmltYWdlcyIsImtpbmQiOiJzdXJmYWNlIiwibGVuZ3RoIjo5M31dLCJidWlsZFJlY2lwZURpZ2VzdCI6InNoYTI1NjpiZjcwOTBjNDY0MWM5NDYxYTQ0MWNkYjJlMGZmYzE1MGQ3NDFiMjhkMjg0MzU4MjZkMGZiMmNhOTc0MWI1MGE2IiwiY29tcGlsZXJEaWdlc3QiOiJzaGEyNTY6ZmU0MWVhNjY4YTBhNDdiZTc0YmUyN2JkOGY0YzhhMGVjN2YwOTZhODkxNTY5ODIwMmZlZjM5N2RkN2I2NWRhZCIsImNyZWF0ZWRBdCI6MTc5MzM3ODk0Mzk4NCwiZGlzdHJpYnV0aW9uUHJvZmlsZSI6ImRldmVsb3BtZW50IiwiZW5naW5lQWJpIjoxLCJob3N0QWJpSGFzaCI6InNoYTI1NjozM2E3N2YyYzQ1MzRjNzA3MTIwOTAyMTQ4NGU3M2Y1NGEzMjY0Nzg2ZTZiMDkzMjNkM2FlODkwMjZhYTJkZmJjIiwiaXJWZXJzaW9uIjoxLCJrZXlJZCI6ImRldi1yb290LTEiLCJtb2R1bGVDb250cmFjdHMiOltdLCJwYXRjaENsYXNzIjoic3VyZmFjZSIsInBhdGNoSWQiOiJ0ZXh0LW9ubHkiLCJwYXRjaFNlcXVlbmNlIjoxLCJwYXRjaFNldERpZ2VzdCI6InNoYTI1NjpmNTczNjdiMDJlNjY5ODcwYmU1YzUxYTNmYTExMWIyMTk3NDg3YmJhNzNhMzk3NDQyMWZiNTdmYzUyMDEwZWU0IiwicGVybWlzc2lvbnMiOltdLCJwbGF0Zm9ybSI6ImZsdXR0ZXJfYW5kcm9pZCIsInByb2plY3RJZCI6ImRlbW8iLCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2VDb21taXQiOiJkZXY6c2hhMjU2OjMzYTk4NjZkNTFkMzVhNDZiNjM2NjNmNThiNDAyNzgzZmEwOGVkZTA2NTNhZDA5MjlhNjcwNmRmNThlZmZlMzYiLCJzdGF0ZVNjaGVtYVZlcnNpb24iOjB9JHZgZBrxNDU/A4rVZV5mXBRSKn96vTzegq9nafmZ6S7VVnB1MdBYPXNERVziMClods3G2kE+QHqzbU0UqLX1VHsicm9vdCI6eyJ0ZXh0IjoicGF0Y2hlZCB0ZXh0IG9ubHkiLCJ0eXBlIjoidGV4dCJ9LCJzY2hlbWFWZXJzaW9uIjoxLCJzdXJmYWNlIjoidGVzdC5pbWFnZXMifQ==';
const _root =
    'bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U';

BugCapsulePatch _openSurface(String bundle, String library) {
  final dir = Directory.systemTemp.createTempSync('surface-widget-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final config = PatchConfig(
    storeDir: dir.path,
    projectId: 'demo',
    applicationId: 'test.images',
    environment: 'staging',
    platform: 'flutter_android',
    distributionProfile: 'development',
    baseBuildId: 'base-images',
    installationId: 'test-install',
    trustRoots: const [_root],
  );
  BugCapsulePatch open() => BugCapsulePatch.open(
    config,
    modules: const [],
    libraryPath: library,
    surfaces: const [
      PatchSurfaceContract(
        id: 'test.images',
        components: ['column', 'list', 'text', 'image'],
        actions: [],
        assets: ['brand.logo'],
      ),
    ],
  );
  final staging = open();
  expect(staging.available, isTrue, reason: staging.unavailableReason);
  staging.stage(base64Decode(bundle));
  staging.close();
  final patch = open();
  expect(patch.available, isTrue, reason: patch.unavailableReason);
  addTearDown(patch.close);
  return patch;
}

void main() {
  final library = Platform.environment['BCPATCH_HOST_LIB'];
  testWidgets('missing nested image falls back to the entire bundled surface', (
    tester,
  ) async {
    final patch = _openSurface(_imageBundle, library!);
    await tester.pumpWidget(
      MaterialApp(
        home: PatchSurfaceView(
          patch: patch,
          id: 'test.images',
          actions: const {},
          bundled: const Text('bundled'),
        ),
      ),
    );
    expect(find.text('bundled'), findsOneWidget);
    expect(find.text('patched'), findsNothing);
    expect(find.byType(Image), findsNothing);
  }, skip: library == null);

  testWidgets('supplied image renders with its accessibility label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final patch = _openSurface(_imageBundle, library!);
    // A valid 1x1 PNG supplied by the host, never decoded from a patch asset.
    final image = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PatchSurfaceView(
          patch: patch,
          id: 'test.images',
          actions: const {},
          images: {'brand.logo': image},
          bundled: const Text('bundled'),
        ),
      ),
    );
    expect(find.text('bundled'), findsNothing);
    expect(find.text('patched'), findsOneWidget);
    await tester.runAsync(
      () => precacheImage(image, tester.element(find.byType(PatchSurfaceView))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(
      tester.widget<Image>(find.byType(Image)).semanticLabel,
      'Brand logo',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, skip: library == null);

  testWidgets('surface with no image needs no image map', (tester) async {
    final patch = _openSurface(_textBundle, library!);
    await tester.pumpWidget(
      MaterialApp(
        home: PatchSurfaceView(
          patch: patch,
          id: 'test.images',
          actions: const {},
          bundled: const Text('bundled'),
        ),
      ),
    );
    expect(find.text('patched text only'), findsOneWidget);
    expect(find.text('bundled'), findsNothing);
  }, skip: library == null);

  testWidgets('falls back to the bundled layout without a runtime', (
    tester,
  ) async {
    final patch = BugCapsulePatch.open(
      const PatchConfig(
        storeDir: '/tmp/x',
        projectId: 'p',
        applicationId: 'a',
        environment: 'e',
        platform: 'flutter_android',
        distributionProfile: 'development',
        baseBuildId: 'b',
        installationId: 'i',
        trustRoots: [],
      ),
      modules: const [],
      libraryPath: '/nonexistent/libbcpatch',
    );
    expect(patch.available, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: PatchSurfaceView(
          patch: patch,
          id: 's',
          actions: const {},
          bundled: const Text('bundled'),
        ),
      ),
    );
    expect(find.text('bundled'), findsOneWidget);
  });
}
