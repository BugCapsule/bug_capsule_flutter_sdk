import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/material.dart';

// Pass your project's SDK token with --dart-define=BUGCAPSULE_TOKEN=...
// Without a token, captures stay on the device.
void main() => BugCapsule.init(
  config: const BugCapsuleConfig(
    token: String.fromEnvironment('BUGCAPSULE_TOKEN'),
    appVersion: '1.0.0',
    appBuild: '1',
  ),
  appRunner: () => runApp(const ExampleApp()),
);

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BugCapsule example',
    navigatorObservers: [BugCapsuleNavigatorObserver()],
    home: const CapturePage(),
  );
}

class CapturePage extends StatelessWidget {
  const CapturePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BugCapsule example')),
    body: Center(
      child: ElevatedButton(
        onPressed: () async {
          final result = await BugCapsule.capture(
            note: 'Captured from the example app',
          );
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Capture result'),
              content: Text(
                result == null ? 'Capture unavailable.' : 'Capsule saved.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        },
        child: const Text('Capture a capsule'),
      ),
    ),
  );
}
