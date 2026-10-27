import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

/// How launchers learn that the app under test died during an attempt and
/// why (crash-capsules §4). Each parser returns null when its input shows
/// no crash; [resolveCrash] then turns an [ObservedCrash] into the
/// attempt's result.
abstract final class CrashDetection {
  static final _fatalSignal = RegExp(r'Fatal signal (\d+) \((SIG[A-Z0-9]+)\)');
  static final _nativeFrame = RegExp(
    r'#\d+ pc [0-9a-fA-F]+\s+(\S+)(?:\s+\(([^)+]+)(?:\+\d+)?\))?',
  );
  static final _fatalException = RegExp(r'FATAL EXCEPTION:');
  static final _exceptionLine = RegExp(
    r'(?:^|\s)((?:[a-zA-Z_$][\w$]*\.)+[A-Z][\w$]*(?:Exception|Error))(?::|\s|$)',
  );
  static final _anr = RegExp(r'ANR in (\S+)');

  /// Logcat (`adb logcat -b crash`, or the device log `flutter run` shows):
  /// a native signal with its tombstone backtrace, a managed crash, an ANR.
  /// [appPaths] mark the app's own frames (default: installed app code
  /// under `/data/app/`).
  static ObservedCrash? fromLog(
    String log, {
    String source = 'logcat',
    bool Function(String path)? appPaths,
  }) {
    final lines = const LineSplitter().convert(log);
    final isApp =
        appPaths ??
        (String p) =>
            (p.startsWith('/data/app/') || p.startsWith('/data/data/')) &&
            !p.endsWith('/libflutter.so');
    for (var i = 0; i < lines.length; i++) {
      final signal = _fatalSignal.firstMatch(lines[i]);
      if (signal != null) {
        String? frame;
        for (final l in lines.skip(i + 1)) {
          final m = _nativeFrame.firstMatch(l);
          if (m != null && m[2] != null && isApp(m[1]!)) {
            frame = m[2];
            break;
          }
        }
        return ObservedCrash(
          type: signal[2],
          mechanism: 'signal',
          signal: int.parse(signal[1]!),
          inAppFrame: frame,
          source: source,
          message: lines[i].trim(),
        );
      }
      if (_fatalException.hasMatch(lines[i])) {
        for (final l in lines.skip(i + 1).take(5)) {
          final m = _exceptionLine.firstMatch(l);
          if (m != null) {
            return ObservedCrash(
              type: m[1],
              mechanism: 'exception',
              source: source,
              message: l.trim(),
            );
          }
        }
      }
      final anr = _anr.firstMatch(lines[i]);
      if (anr != null) {
        return ObservedCrash(
          type: 'ApplicationNotResponding',
          mechanism: 'anr',
          source: source,
          message: lines[i].trim(),
        );
      }
    }
    return null;
  }

  static final _exitRecord = RegExp(r'ApplicationExitInfo #\d+:');
  static final _exitPid = RegExp(r'\bpid=(\d+)');
  static final _exitTimestamp = RegExp(r'timestamp=(\S+ \S+)');
  static final _exitReason = RegExp(r'reason=(\d+) \((\w+)\)');
  static final _exitStatus = RegExp(r'\bstatus=(-?\d+)');

  /// The records of `adb shell dumpsys activity exit-info <package>`
  /// (Android 11+), newest first, keyed `<timestamp>|<pid>` so a launcher
  /// can tell the ones an attempt added.
  static List<(String, ObservedCrash?)> exitRecords(String dumpsys) {
    final out = <(String, ObservedCrash?)>[];
    final starts = _exitRecord.allMatches(dumpsys).toList();
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1].start : dumpsys.length;
      final record = dumpsys.substring(starts[i].end, end);
      final key =
          '${_exitTimestamp.firstMatch(record)?[1]}|${_exitPid.firstMatch(record)?[1]}';
      final reason = _exitReason.firstMatch(record)?[2];
      final status = int.tryParse(_exitStatus.firstMatch(record)?[1] ?? '');
      final crash = switch (reason) {
        'CRASH_NATIVE' => ObservedCrash(
          type: status == null ? null : ObservedCrash.signalName(status),
          mechanism: 'signal',
          signal: status,
          source: 'exit_info',
        ),
        'CRASH' => const ObservedCrash(
          mechanism: 'exception',
          source: 'exit_info',
        ),
        'ANR' => const ObservedCrash(
          type: 'ApplicationNotResponding',
          mechanism: 'anr',
          source: 'exit_info',
        ),
        'LOW_MEMORY' => const ObservedCrash(
          type: 'OutOfMemory',
          mechanism: 'oom',
          source: 'exit_info',
        ),
        _ => null,
      };
      out.add((key, crash));
    }
    return out;
  }

  /// The death [after] adds to [before] (both `dumpsys activity exit-info`
  /// output), refined by the crash buffer [log] when it names the type,
  /// signal or frame.
  static ObservedCrash? fromExitInfo(
    String before,
    String after, {
    String? log,
  }) {
    final known = {for (final (k, _) in exitRecords(before)) k};
    ObservedCrash? exit;
    for (final (key, crash) in exitRecords(after)) {
      if (known.contains(key)) continue;
      if (crash != null) {
        exit = crash;
        break;
      }
    }
    final fromLog = log == null ? null : CrashDetection.fromLog(log);
    if (exit == null) return fromLog;
    if (fromLog == null) return exit;
    // The log has the names and the frame; the exit record the cause.
    return ObservedCrash(
      type: fromLog.type ?? exit.type,
      mechanism: fromLog.mechanism ?? exit.mechanism,
      signal: fromLog.signal ?? exit.signal,
      inAppFrame: fromLog.inAppFrame,
      source: 'exit_info',
      message: fromLog.message,
    );
  }

  /// An Apple crash report (`.ips`, macOS 12+ / Xcode 13+: a JSON header
  /// line, then the JSON report). Null for other reports (hangs, jetsam
  /// without an exception).
  static ObservedCrash? fromIps(String text) {
    final newline = text.indexOf('\n');
    if (newline < 0) return null;
    final Map<String, Object?> report;
    try {
      report = (jsonDecode(text.substring(newline + 1)) as Map)
          .cast<String, Object?>();
    } catch (_) {
      return null;
    }
    final exception = (report['exception'] as Map?)?.cast<String, Object?>();
    if (exception == null) return null;
    final signalName = exception['signal'] as String?;
    int? signal;
    for (var n = 1; n < 32 && signalName != null; n++) {
      if (ObservedCrash.signalName(n) == signalName) {
        signal = n;
        break;
      }
    }
    final images = [
      for (final i in (report['usedImages'] as List?) ?? const [])
        (i as Map).cast<String, Object?>(),
    ];
    bool isApp(Object? index) {
      if (index is! int || index < 0 || index >= images.length) return false;
      final path = '${images[index]['path'] ?? ''}';
      return path.contains('.app/') &&
          !path.contains('/Flutter.framework/') &&
          !path.contains('/Frameworks/libswift');
    }

    String? frame;
    final threads = (report['threads'] as List?) ?? const [];
    final faulting = report['faultingThread'];
    final crashed = faulting is int && faulting < threads.length
        ? threads[faulting]
        : threads.cast<Object?>().firstWhere(
            (t) => t is Map && t['triggered'] == true,
            orElse: () => null,
          );
    if (crashed is Map) {
      for (final f in (crashed['frames'] as List?) ?? const []) {
        if (f is Map && f['symbol'] is String && isApp(f['imageIndex'])) {
          frame = f['symbol'] as String;
          break;
        }
      }
    }
    final type = exception['type'] as String?;
    return ObservedCrash(
      type: type ?? signalName,
      mechanism: type != null && type.startsWith('EXC_')
          ? 'mach_exception'
          : 'signal',
      signal: signal,
      inAppFrame: frame,
      source: 'crash_report',
      message: [
        ?type,
        if (signalName != null) '($signalName)',
        if (exception['subtype'] is String) exception['subtype'] as String,
      ].join(' '),
    );
  }

  /// The newest crash report of [bundleId] written at or after [since] in
  /// [directory] (default `~/Library/Logs/DiagnosticReports`, where
  /// simulator apps' crashes land).
  static ObservedCrash? findIosCrashReport(
    String bundleId, {
    required DateTime since,
    Directory? directory,
  }) {
    final dir =
        directory ??
        Directory(
          '${Platform.environment['HOME'] ?? ''}/Library/Logs/DiagnosticReports',
        );
    if (!dir.existsSync()) return null;
    final reports =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.ips') &&
                  !f.statSync().modified.isBefore(
                    since.subtract(const Duration(seconds: 1)),
                  ),
            )
            .toList()
          ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
    for (final f in reports) {
      try {
        final text = f.readAsStringSync();
        final header = jsonDecode(text.substring(0, text.indexOf('\n')));
        if (header is! Map || header['bundleID'] != bundleId) continue;
        final crash = fromIps(text);
        if (crash != null) return crash;
      } catch (_) {}
    }
    return null;
  }

  /// `flutter run` output after the app went away before reporting: a
  /// crash in the device log it showed, or an unknown death when the tool
  /// lost the app.
  static ObservedCrash? fromFlutterRun(String log) {
    final crash = fromLog(log, source: 'process_exit');
    if (crash != null) return crash;
    if (log.contains('Lost connection to device') ||
        log.contains('Application finished') ||
        log.contains('Service protocol connection closed')) {
      return const ObservedCrash(
        source: 'process_exit',
        message: 'flutter run lost the app',
      );
    }
    return null;
  }

  /// A crash the replay runner reported as an instrumentation status
  /// (`INSTRUMENTATION_STATUS: bugcapsule_crash=<json>`), when it outlived
  /// the app.
  static ObservedCrash? fromInstrumentationStatus(String log) {
    const key = 'bugcapsule_crash=';
    for (final line in const LineSplitter().convert(log)) {
      final i = line.indexOf(key);
      if (i < 0) continue;
      try {
        return ObservedCrash.fromJson(
          (jsonDecode(line.substring(i + key.length)) as Map)
              .cast<String, Object?>(),
        );
      } catch (_) {}
    }
    return null;
  }

  static final _xctestCrash = RegExp(
    r'(crash|Crash|crashed|not running|Lost connection to the application)',
  );
  static final _crashName = RegExp(r'\b(SIG[A-Z]{2,}|EXC_[A-Z_]+)\b');

  /// `xcodebuild test` output: XCTest reports the app under test crashing
  /// (`… crashed in …`, `Lost connection to the application`).
  static ObservedCrash? fromXctestLog(String log) {
    for (final line in const LineSplitter().convert(log)) {
      if (!_xctestCrash.hasMatch(line) || line.contains('BUGCAPSULE_RESULT')) {
        continue;
      }
      final names = [for (final m in _crashName.allMatches(line)) m[1]!];
      final name = names.firstOrNull;
      final sig = names.where((n) => n.startsWith('SIG')).firstOrNull;
      int? signal;
      for (var n = 1; n < 32 && sig != null; n++) {
        if (ObservedCrash.signalName(n) == sig) {
          signal = n;
          break;
        }
      }
      return ObservedCrash(
        type: name,
        signal: signal,
        mechanism: name == null
            ? null
            : name.startsWith('EXC_')
            ? 'mach_exception'
            : 'signal',
        source: 'xctest',
        message: line.trim(),
      );
    }
    return null;
  }

  /// `am instrument` said the instrumented process died.
  static bool instrumentationCrashed(String log) =>
      log.contains('shortMsg=Process crashed') ||
      log.contains('Process crashed.') ||
      log.contains('INSTRUMENTATION_FAILED');
}
