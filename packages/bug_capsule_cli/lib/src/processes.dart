import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Child processes started for a replay, so Ctrl-C, timeouts and errors can
/// stop all of them (builds, servers, browsers, instrumentation runs).
abstract final class Processes {
  static final Set<Process> _live = {};
  static final List<Future<void> Function()> _cleanups = [];

  /// Starts [exe] and tracks it until it exits.
  static Future<Process> start(String exe, List<String> args,
      {String? workingDirectory, Map<String, String>? environment, bool runInShell = false}) async {
    final p = await Process.start(exe, args,
        workingDirectory: workingDirectory, environment: environment, runInShell: runInShell);
    _live.add(p);
    unawaited(p.exitCode.then((_) => _live.remove(p)));
    return p;
  }

  /// Registers cleanup that must run on exit or interruption (e.g. removing an
  /// `adb reverse` rule). Returns a function that runs and unregisters it.
  static Future<void> Function() onCleanup(Future<void> Function() fn) {
    _cleanups.add(fn);
    return () async {
      if (_cleanups.remove(fn)) await fn();
    };
  }

  /// Kills every tracked process (SIGTERM, then SIGKILL after [grace]) and
  /// runs registered cleanups.
  static Future<void> stopAll({Duration grace = const Duration(seconds: 3)}) async {
    final live = _live.toList();
    for (final p in live) {
      p.kill(ProcessSignal.sigterm);
    }
    await Future.wait([
      for (final p in live)
        p.exitCode.timeout(grace, onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        }),
    ]);
    final cleanups = _cleanups.toList();
    _cleanups.clear();
    for (final c in cleanups.reversed) {
      try {
        await c().timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
  }

  /// Kills [p] and its process group when possible.
  static Future<int> kill(Process p, {Duration grace = const Duration(seconds: 3)}) async {
    p.kill(ProcessSignal.sigterm);
    return p.exitCode.timeout(grace, onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}

/// Runs a command to completion with a [timeout]; throws [StateError] with the
/// tail of its output when it fails. Output is streamed when [verbose].
Future<String> runChecked(
  String exe,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  required bool verbose,
  String? label,
  Duration timeout = const Duration(minutes: 20),
  bool runInShell = false,
}) async {
  final p = await Processes.start(exe, args,
      workingDirectory: workingDirectory, environment: environment, runInShell: runInShell);
  final out = StringBuffer();
  final subs = [
    p.stdout.transform(utf8.decoder).listen((s) {
      out.write(s);
      if (verbose) stdout.write(s);
    }),
    p.stderr.transform(utf8.decoder).listen((s) {
      out.write(s);
      if (verbose) stderr.write(s);
    }),
  ];
  final code = await p.exitCode.timeout(timeout, onTimeout: () async {
    await Processes.kill(p);
    throw StateError('${label ?? exe} timed out after ${timeout.inSeconds}s');
  });
  for (final s in subs) {
    await s.cancel();
  }
  if (code != 0) {
    if (!verbose) stderr.write(tail(out.toString(), 40));
    throw StateError('${label ?? '$exe ${args.join(' ')}'} failed (exit $code)');
  }
  return out.toString();
}

/// The last [lines] lines of [s].
String tail(String s, [int lines = 30]) {
  final all = s.trimRight().split('\n');
  return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
}

/// Runs [shellCommand] through `/bin/sh -c` (project-configured commands
/// such as `npm run build`).
Future<String> runShell(String shellCommand,
        {required String workingDirectory,
        Map<String, String>? environment,
        required bool verbose,
        String? label,
        Duration timeout = const Duration(minutes: 20)}) =>
    runChecked('/bin/sh', ['-c', shellCommand],
        workingDirectory: workingDirectory,
        environment: environment,
        verbose: verbose,
        label: label ?? shellCommand,
        timeout: timeout);
