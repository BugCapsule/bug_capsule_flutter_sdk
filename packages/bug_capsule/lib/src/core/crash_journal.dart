/// The crash journal (crash-capsules §1-§2): while a session records, the
/// flight recorder is mirrored to disk so that a crash that ends the process
/// (a native signal, an ANR kill, a low-memory kill) still leaves a capsule,
/// built on the next launch.
///
/// Layout, one directory per process under `<storage>/journal/<pid>/`:
///
/// * `header.json`: every capsule manifest field known while the app runs
///   (written at start, rewritten when one changes);
/// * `checkpoints/<afterSeq>.json`: the launch checkpoint while the whole
///   session is still within the recorder's window, and the newest periodic
///   checkpoint;
/// * `events/<firstSeq>.jsonl`: the recorded events, one per line, already
///   redacted. A new file starts at each checkpoint, so eviction deletes
///   whole files.
///
/// The recording side ([CrashJournal]) only hands events to a [JournalSink];
/// the [JournalWriter] behind it (in its own isolate in apps) batches them
/// into one write per flush, at least every 250 ms.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'capsule.dart';
import 'capsule_validator.dart';
import 'codec.dart';
import 'event.dart';
import 'failure.dart';
import 'flight_recorder.dart';
import 'http_capture.dart';
import 'interactions.dart';
import 'monitoring/model.dart';

abstract final class CrashJournalLayout {
  static const directoryName = 'journal';
  static const header = 'header.json';
  static const checkpoints = 'checkpoints';
  static const events = 'events';

  /// Present once the size cap deleted events the newest checkpoint needs.
  static const truncated = 'truncated';

  /// Journals older than this are deleted whatever claims them.
  static const maxAge = Duration(days: 7);

  /// Events are flushed at least this often.
  static const flushInterval = Duration(milliseconds: 250);

  /// Version of the journal format (`header.journal`).
  static const version = 1;
}

// ------------------------------------------------------------------ writer

class _EventsFile {
  _EventsFile(this.lastSeq, this.bytes);
  int lastSeq;
  int bytes;
}

/// Applies batches of journal operations to one journal directory with
/// synchronous file I/O: in the writer isolate in apps, inline in tests.
///
/// Operations (lists, so they cross isolates as plain data):
/// `['h', header]`, `['c', checkpoint]`, `['e', firstSeq, events]`,
/// `['l']` (the launch checkpoint no longer covers the session),
/// `['r', launch?, periodic?, events]` (rewrite everything),
/// `['m', maxBytes]` and `['x']` (delete the journal).
class JournalWriter {
  JournalWriter(this.dir, {required this.maxBytes});

  final Directory dir;

  /// At most this much on disk (2 × `maxCapsuleBytes`); past it the oldest
  /// events file goes, and the launch checkpoint with it.
  int maxBytes;

  final SplayTreeMap<int, _EventsFile> _files = SplayTreeMap();
  int? _launchBytes;
  (int, int)? _periodic;
  bool _launchCovers = true;
  bool _stopped = false;

  /// Bytes of checkpoints and events on disk.
  int get totalBytes =>
      (_launchBytes ?? 0) +
      (_periodic?.$2 ?? 0) +
      _files.values.fold(0, (s, f) => s + f.bytes);

  bool get stopped => _stopped;

  void apply(List<Object?> batch) {
    if (_stopped) return;
    try {
      for (final op in batch) {
        _apply(op as List<Object?>);
        if (_stopped) return;
      }
      _enforceCap();
    } catch (_) {
      // A journal that cannot be kept complete is not kept at all.
      _stop();
    }
  }

  void _apply(List<Object?> op) {
    switch (op[0]) {
      case 'h':
        _writeJson(CrashJournalLayout.header, op[1]);
      case 'c':
        _checkpoint((op[1] as Map).cast<String, Object?>());
      case 'e':
        _append(op[1] as int, op[2] as List<Object?>);
      case 'l':
        _dropLaunch();
      case 'r':
        _resync(
          op[1] as Map<Object?, Object?>?,
          op[2] as Map<Object?, Object?>?,
          op[3] as List<Object?>,
        );
      case 'm':
        maxBytes = op[1] as int;
      case 'x':
        _stop();
    }
  }

  void _stop() {
    _stopped = true;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  String _path(String relative) => '${dir.path}/$relative';

  int _writeJson(String relative, Object? json) {
    final bytes = utf8.encode(jsonEncode(json));
    final file = File(_path(relative));
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
    return bytes.length;
  }

  void _delete(String relative) {
    final f = File(_path(relative));
    if (f.existsSync()) f.deleteSync();
  }

  static String _checkpointFile(int afterSeq) =>
      '${CrashJournalLayout.checkpoints}/$afterSeq.json';
  static String _eventsFile(int firstSeq) =>
      '${CrashJournalLayout.events}/$firstSeq.jsonl';

  void _checkpoint(Map<String, Object?> json) {
    final afterSeq = json['afterSeq'] as int;
    final bytes = _writeJson(_checkpointFile(afterSeq), json);
    if (json['kind'] == CheckpointKind.launch.name) {
      _launchBytes = bytes;
      return;
    }
    final previous = _periodic;
    if (previous != null && previous.$1 != afterSeq) {
      _delete(_checkpointFile(previous.$1));
    }
    _periodic = (afterSeq, bytes);
    if (!_launchCovers) _dropThrough(afterSeq);
  }

  void _dropLaunch() {
    _launchCovers = false;
    if (_launchBytes != null) {
      _delete(_checkpointFile(0));
      _launchBytes = null;
    }
    final periodic = _periodic;
    if (periodic != null) _dropThrough(periodic.$1);
  }

  /// Deletes the events files no event after [afterSeq] is in.
  void _dropThrough(int afterSeq) {
    for (final first in _files.keys.toList()) {
      if (_files[first]!.lastSeq <= afterSeq) {
        _delete(_eventsFile(first));
        _files.remove(first);
      }
    }
  }

  void _append(int firstSeq, List<Object?> events) {
    if (events.isEmpty) return;
    final out = StringBuffer();
    var last = 0;
    for (final e in events) {
      out
        ..write(jsonEncode(e))
        ..write('\n');
      last = ((e as Map)['seq'] as int?) ?? last;
    }
    final bytes = utf8.encode(out.toString());
    final file = File(_path(_eventsFile(firstSeq)));
    file.parent.createSync(recursive: true);
    // One write per flush.
    file.writeAsBytesSync(bytes, mode: FileMode.append, flush: false);
    final entry = _files.putIfAbsent(firstSeq, () => _EventsFile(last, 0));
    entry
      ..lastSeq = max(entry.lastSeq, last)
      ..bytes += bytes.length;
  }

  void _resync(
    Map<Object?, Object?>? launch,
    Map<Object?, Object?>? periodic,
    List<Object?> events,
  ) {
    for (final sub in [
      CrashJournalLayout.checkpoints,
      CrashJournalLayout.events,
    ]) {
      final d = Directory(_path(sub));
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    _files.clear();
    _launchBytes = null;
    _periodic = null;
    _launchCovers = launch != null;
    if (launch != null) _checkpoint(launch.cast<String, Object?>());
    if (periodic != null) _checkpoint(periodic.cast<String, Object?>());
    final boundary = (periodic?['afterSeq'] as int?) ?? 0;
    final before = <Object?>[];
    final after = <Object?>[];
    for (final e in events) {
      (((e as Map)['seq'] as int) <= boundary ? before : after).add(e);
    }
    for (final group in [before, after]) {
      if (group.isNotEmpty) {
        _append((group.first as Map)['seq'] as int, group);
      }
    }
  }

  void _enforceCap() {
    var marked = false;
    while (totalBytes > maxBytes && _files.isNotEmpty) {
      final first = _files.firstKey()!;
      _delete(_eventsFile(first));
      _files.remove(first);
      if (_launchBytes != null) {
        _delete(_checkpointFile(0));
        _launchBytes = null;
      }
      _launchCovers = false;
      if (!marked) {
        File(_path(CrashJournalLayout.truncated)).writeAsStringSync('');
        marked = true;
      }
    }
  }
}

// ------------------------------------------------------------------- sinks

/// Where [CrashJournal] hands its batches.
abstract interface class JournalSink {
  void send(List<Object?> batch);

  /// Waits for what was sent to be written.
  Future<void> close();
}

/// Writes on the calling isolate (tests, and the fallback when the writer
/// isolate cannot start).
class InlineJournalSink implements JournalSink {
  InlineJournalSink(this.writer);

  final JournalWriter writer;

  @override
  void send(List<Object?> batch) => writer.apply(batch);

  @override
  Future<void> close() async {}
}

/// Writes in a background isolate: the UI isolate only hands the batch over.
class IsolateJournalSink implements JournalSink {
  IsolateJournalSink._(this._dir, this._maxBytes);

  /// Starts the writer isolate; batches sent before it is up are queued.
  static IsolateJournalSink start(Directory dir, {required int maxBytes}) =>
      IsolateJournalSink._(dir, maxBytes).._spawn();

  final Directory _dir;
  final int _maxBytes;
  final List<List<Object?>> _queue = [];
  final Completer<void> _ready = Completer();
  SendPort? _port;
  JournalWriter? _fallback;
  bool _closed = false;

  Future<void> _spawn() async {
    final init = ReceivePort();
    try {
      await Isolate.spawn(_journalWriterMain, [
        init.sendPort,
        _dir.path,
        _maxBytes,
      ], debugName: 'bugcapsule-journal');
      _port = await init.first.timeout(const Duration(seconds: 5)) as SendPort;
    } catch (_) {
      _fallback = JournalWriter(_dir, maxBytes: _maxBytes);
    } finally {
      init.close();
    }
    for (final batch in _queue) {
      _deliver(batch);
    }
    _queue.clear();
    _ready.complete();
  }

  void _deliver(List<Object?> batch) {
    final port = _port;
    if (port != null) {
      port.send(batch);
    } else {
      _fallback?.apply(batch);
    }
  }

  @override
  void send(List<Object?> batch) {
    if (_closed) return;
    if (_ready.isCompleted) {
      _deliver(batch);
    } else {
      _queue.add(batch);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ready.future;
    final port = _port;
    if (port == null) return;
    final done = ReceivePort();
    port.send(['q', done.sendPort]);
    await done.first
        .timeout(const Duration(seconds: 2), onTimeout: () => null)
        .whenComplete(done.close);
  }
}

void _journalWriterMain(List<Object?> args) {
  final reply = args[0] as SendPort;
  final writer = JournalWriter(
    Directory(args[1] as String),
    maxBytes: args[2] as int,
  );
  final port = ReceivePort();
  reply.send(port.sendPort);
  port.listen((message) {
    final batch = message as List<Object?>;
    if (batch.isNotEmpty && batch.first == 'q') {
      (batch[1] as SendPort).send(true);
      port.close();
      return;
    }
    writer.apply(batch);
  });
}

// --------------------------------------------------------- recording side

/// Mirrors a [FlightRecorder] into a journal directory (see the library
/// comment). Events are queued as they are recorded and handed to the sink
/// at least every [flushInterval], and at once on a checkpoint and on
/// [flush] (a failure, going to the background).
class CrashJournal implements FlightRecorderListener {
  CrashJournal._(
    this.directory,
    this._sink,
    this._recorder,
    this.flushInterval,
  );

  /// Starts journaling [recorder] (launch checkpoint and [header] first).
  static CrashJournal start({
    required Directory directory,
    required FlightRecorder recorder,
    required Map<String, Object?> header,
    required JournalSink sink,
    Duration flushInterval = CrashJournalLayout.flushInterval,
  }) {
    final journal = CrashJournal._(directory, sink, recorder, flushInterval);
    journal._ops.add(['h', header]);
    if (recorder.lastSeq > 0 || recorder.periodicCheckpoints.isNotEmpty) {
      journal.onRewrite(recorder);
    } else {
      journal._ops.add(['c', recorder.launch.toJson()]);
    }
    recorder.listener = journal;
    journal.flush();
    return journal;
  }

  final Directory directory;
  final JournalSink _sink;
  final FlightRecorder _recorder;
  final Duration flushInterval;

  /// Operations not handed to the sink yet, in order.
  final List<List<Object?>> _ops = [];
  final List<BugCapsuleEvent> _pending = [];
  int? _currentFile;
  Timer? _timer;
  bool _launchDropped = false;
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  void onEvent(BugCapsuleEvent event) {
    if (_closed) return;
    _pending.add(event);
    _schedule();
  }

  @override
  void onCheckpoint(Checkpoint checkpoint) {
    // A periodic checkpoint before any event is the launch checkpoint again.
    if (_closed || checkpoint.afterSeq == 0) return;
    _takePending();
    _ops.add(['c', checkpoint.toJson()]);
    _currentFile = null;
    flush();
  }

  @override
  void onRewrite(FlightRecorder recorder) {
    if (_closed) return;
    // What was written with the old rules is replaced, not appended to.
    _pending.clear();
    _ops.removeWhere((op) => op[0] == 'e' || op[0] == 'c' || op[0] == 'l');
    final periodic = recorder.periodicCheckpoints.lastOrNull;
    _ops.add([
      'r',
      recorder.launchCoversWindow ? recorder.launch.toJson() : null,
      periodic == null || periodic.afterSeq == 0 ? null : periodic.toJson(),
      [for (final e in recorder.events) e.toJson()],
    ]);
    _launchDropped = !recorder.launchCoversWindow;
    _currentFile = null;
    _schedule();
  }

  /// Rewrites `header.json` with the next flush.
  void updateHeader(Map<String, Object?> header) {
    if (_closed) return;
    _ops
      ..removeWhere((op) => op[0] == 'h')
      ..add(['h', header]);
    _schedule();
  }

  set maxBytes(int value) {
    if (_closed) return;
    _ops.add(['m', value]);
    _schedule();
  }

  void _schedule() => _timer ??= Timer(flushInterval, flush);

  /// Hands everything queued to the writer now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_closed) return;
    if (!_launchDropped && !_recorder.launchCoversWindow) {
      _takePending();
      _ops.add(['l']);
      _launchDropped = true;
    }
    _takePending();
    if (_ops.isEmpty) return;
    final batch = List<Object?>.of(_ops);
    _ops.clear();
    _sink.send(batch);
  }

  void _takePending() {
    if (_pending.isEmpty) return;
    final file = _currentFile ??= _pending.first.seq;
    _ops.add([
      'e',
      file,
      [for (final e in _pending) e.toJson()],
    ]);
    _pending.clear();
  }

  void _detach() {
    _timer?.cancel();
    _timer = null;
    _closed = true;
    if (identical(_recorder.listener, this)) _recorder.listener = null;
  }

  /// Flushes and stops; the journal stays on disk (the process may still
  /// die before it ends).
  Future<void> close() async {
    if (_closed) return;
    flush();
    _detach();
    await _sink.close();
  }

  /// Stops and deletes the journal (recording stopped: a session that does
  /// not record keeps no journal).
  Future<void> discard() async {
    if (_closed) return;
    _pending.clear();
    _ops.clear();
    _detach();
    _sink.send([
      ['x'],
    ]);
    await _sink.close();
  }
}

// ----------------------------------------------------------------- reading

/// A journal's header and file times, read without its events.
class JournalInfo {
  const JournalInfo({
    required this.dir,
    required this.lastWrite,
    this.processId,
    this.pid,
    this.startedAt,
  });

  final Directory dir;
  final String? processId;
  final int? pid;

  /// When the journaled session started (`session.startedAt`).
  final DateTime? startedAt;

  /// Newest modification time of a file in the journal.
  final DateTime lastWrite;

  static JournalInfo? read(Directory dir) {
    try {
      final header = _readHeader(dir);
      if (header == null) return null;
      final session = header['session'];
      return JournalInfo(
        dir: dir,
        processId: header['processId'] as String?,
        pid: header['pid'] as int?,
        startedAt: session is Map
            ? DateTime.tryParse('${session['startedAt']}')
            : null,
        lastWrite: _lastWrite(dir),
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, Object?>? _readHeader(Directory dir) {
  final file = File('${dir.path}/${CrashJournalLayout.header}');
  if (!file.existsSync()) return null;
  final json = jsonDecode(file.readAsStringSync());
  return json is Map ? json.cast<String, Object?>() : null;
}

DateTime _lastWrite(Directory dir) {
  var newest = dir.statSync().modified;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File) {
      final m = e.statSync().modified;
      if (m.isAfter(newest)) newest = m;
    }
  }
  return newest;
}

/// Everything a journal holds.
class JournalContents {
  const JournalContents({
    required this.dir,
    required this.header,
    required this.events,
    required this.truncated,
    this.launch,
    this.periodic,
  });

  final Directory dir;
  final Map<String, Object?> header;

  /// Present while every event after it is on disk.
  final Checkpoint? launch;

  /// The newest periodic checkpoint.
  final Checkpoint? periodic;

  /// Every journaled event, by `seq`. A last line cut by the crash is skipped.
  final List<BugCapsuleEvent> events;

  /// The size cap deleted events (the periodic window may have a gap).
  final bool truncated;

  static JournalContents? read(Directory dir) {
    final header = _readHeader(dir);
    if (header == null) return null;
    Checkpoint? launch;
    Checkpoint? periodic;
    final cps = Directory('${dir.path}/${CrashJournalLayout.checkpoints}');
    if (cps.existsSync()) {
      for (final f in cps.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          final cp = Checkpoint.fromJson(
            (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
          );
          if (cp.kind == CheckpointKind.launch) {
            launch = cp;
          } else if (periodic == null || cp.afterSeq > periodic.afterSeq) {
            periodic = cp;
          }
        } catch (_) {}
      }
    }
    final bySeq = SplayTreeMap<int, BugCapsuleEvent>();
    final evDir = Directory('${dir.path}/${CrashJournalLayout.events}');
    if (evDir.existsSync()) {
      for (final f in evDir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.jsonl')) continue;
        for (final line in const LineSplitter().convert(
          utf8.decode(f.readAsBytesSync(), allowMalformed: true),
        )) {
          if (line.isEmpty) continue;
          try {
            final e = BugCapsuleEvent.fromJson(
              (jsonDecode(line) as Map).cast<String, Object?>(),
            );
            bySeq[e.seq] = e;
          } catch (_) {}
        }
      }
    }
    return JournalContents(
      dir: dir,
      header: header,
      launch: launch,
      periodic: periodic,
      events: bySeq.values.toList(),
      truncated: File(
        '${dir.path}/${CrashJournalLayout.truncated}',
      ).existsSync(),
    );
  }
}

/// The journals of a storage directory.
abstract final class CrashJournals {
  static Directory rootOf(Directory storage) =>
      Directory('${storage.path}/${CrashJournalLayout.directoryName}');

  static Directory dirFor(Directory storage, String processId) =>
      Directory('${rootOf(storage).path}/$processId');

  /// Frees `journal/<processId>` for this process: a directory there is an
  /// earlier process's that had the same pid; it is moved aside (its header
  /// still names its process) so it can still be claimed.
  static Directory reserve(Directory storage, String processId) {
    final dir = dirFor(storage, processId);
    if (dir.existsSync()) {
      dir.renameSync('${dir.path}~${DateTime.now().microsecondsSinceEpoch}');
    }
    return dir;
  }

  /// Journals of earlier processes (everything but [except]).
  static List<JournalInfo> list(Directory storage, {Directory? except}) {
    final root = rootOf(storage);
    if (!root.existsSync()) return const [];
    final skip = except == null ? null : _normalized(except);
    return [
      for (final d in root.listSync().whereType<Directory>())
        if (_normalized(d) != skip) ?JournalInfo.read(d),
    ];
  }

  static String _normalized(Directory d) =>
      d.absolute.path.replaceAll(RegExp(r'/+$'), '');

  /// The journal of the process a fatal event of an earlier run is about,
  /// or null. Rules, in order:
  ///
  /// 1. [journalId] (the event's mirrored scope named the journal of its
  ///    process: Android, and iOS crash reports, attach the crashed
  ///    process's scope): the journal of that process id that started
  ///    before the crash;
  /// 2. [lastRunCrashed]: the previous process's journal (the newest),
  ///    when the crash falls between its start and five minutes after its
  ///    last write;
  /// 3. none.
  static JournalInfo? forCrash(
    List<JournalInfo> journals, {
    required DateTime crashedAt,
    required bool lastRunCrashed,
    String? journalId,
  }) {
    final newest = [...journals]
      ..sort(
        (a, b) =>
            (b.startedAt ?? b.lastWrite).compareTo(a.startedAt ?? a.lastWrite),
      );
    const skew = Duration(minutes: 1);
    bool startedBefore(JournalInfo j) =>
        j.startedAt == null || !j.startedAt!.subtract(skew).isAfter(crashedAt);
    if (journalId != null) {
      return newest
          .where((j) => j.processId == journalId && startedBefore(j))
          .firstOrNull;
    }
    if (!lastRunCrashed || newest.isEmpty) return null;
    final previous = newest.first;
    final inWindow =
        startedBefore(previous) &&
        !crashedAt.isAfter(previous.lastWrite.add(const Duration(minutes: 5)));
    return inWindow ? previous : null;
  }

  /// Deletes every journal but [keep]; with [olderThan], only those last
  /// written before it.
  static void sweep(Directory storage, {Directory? keep, DateTime? olderThan}) {
    final root = rootOf(storage);
    if (!root.existsSync()) return;
    final skip = keep == null ? null : _normalized(keep);
    for (final d in root.listSync().whereType<Directory>()) {
      if (_normalized(d) == skip) continue;
      try {
        if (olderThan != null && !_lastWrite(d).isBefore(olderThan)) continue;
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------- building

/// The crash a fatal native event reports, as a capsule failure.
class CrashFailure {
  const CrashFailure(this.record, this.mechanism);

  /// `t` is 0: the builder sets it from the crash time.
  final FailureRecord record;

  /// The event's mechanism type (`signal`, `mach_exception`, `anr`, `oom`,
  /// `metrickit`), for `labels["crash.mechanism"]`.
  final String mechanism;

  factory CrashFailure.fromEvent(ErrorEvent event) {
    final exception = event.exceptions.lastOrNull;
    final raw = exception?.mechanism?.type ?? 'signal';
    final mechanism = switch (raw.toLowerCase()) {
      final m when m.contains('mach') => 'mach_exception',
      final m when m.contains('anr') || m.contains('hang') => 'anr',
      final m when m.contains('oom') || m.contains('memory') => 'oom',
      final m when m.contains('metrickit') => 'metrickit',
      _ => 'signal',
    };
    final type = switch (mechanism) {
      'anr' => 'ApplicationNotResponding',
      'oom' => 'OutOfMemory',
      _ => exception?.type ?? 'NativeCrash',
    };
    final data = exception?.mechanism?.data;
    final signal = data?['signal'];
    var frames = exception?.frames ?? const <EventFrame>[];
    if (frames.isEmpty) {
      final crashed = event.threads
          ?.where((t) => t['crashed'] == true)
          .firstOrNull;
      final stack = crashed?['stacktrace'];
      final list = stack is Map ? stack['frames'] : null;
      if (list is List) {
        frames = [
          for (final f in list)
            if (f is Map) EventFrame.fromJson(f.cast<String, Object?>()),
        ];
      }
    }
    // Frames are oldest first; the crash is at the end.
    final crashFirst = frames.reversed.toList();
    final inApp = crashFirst
        .where((f) => f.inApp == true && f.function != null)
        .firstOrNull;
    final stack = [
      for (var i = 0; i < crashFirst.length && i < 50; i++)
        '#$i ${crashFirst[i].function ?? crashFirst[i].instructionAddr ?? '?'}'
            '${crashFirst[i].package == null ? '' : ' (${crashFirst[i].package!.split('/').last})'}',
    ].join('\n');
    return CrashFailure(
      FailureRecord.crash(
        type: type,
        message: exception?.value ?? event.message ?? type,
        stack: stack.isEmpty ? null : stack,
        crash: CrashInfo(
          mechanism: mechanism,
          signal: signal is num ? signal.toInt() : null,
          inAppFrame: inApp?.function,
        ),
        t: 0,
      ),
      raw,
    );
  }
}

/// What the next launch knows about a crash it builds a capsule for.
class CrashCapsuleRequest {
  const CrashCapsuleRequest({
    required this.capsuleId,
    required this.createdAt,
    required this.failure,
    required this.monitoring,
    required this.maxCapsuleBytes,
    this.crashedAt,
  });

  final String capsuleId;
  final DateTime createdAt;
  final CrashFailure failure;
  final CapsuleMonitoring monitoring;
  final int maxCapsuleBytes;

  /// When the process died, if the event knows.
  final DateTime? crashedAt;
}

/// A crash capsule, encoded.
class CrashCapsuleBuild {
  const CrashCapsuleBuild(this.bytes, this.eligibility, this.checkpointKind);

  final List<int> bytes;
  final Eligibility eligibility;
  final CheckpointKind checkpointKind;
}

/// Builds the crash capsule of [journal] (crash-capsules §2): the launch
/// checkpoint when every event after it is on disk, else the newest
/// periodic one; the periodic one too when the launch capsule is over
/// `maxCapsuleBytes`. Null when there is no usable checkpoint, the capsule
/// is still too big, or it would not validate.
CrashCapsuleBuild? buildCrashCapsule(
  JournalContents journal,
  CrashCapsuleRequest request,
) {
  final candidates = [
    if (journal.launch != null && !journal.truncated) journal.launch!,
    ?journal.periodic,
  ];
  for (final checkpoint in candidates) {
    final capsule = crashCapsuleFrom(journal, request, checkpoint);
    if (capsule == null) continue;
    if (validateCapsuleDocument(CapsuleCodec.toJson(capsule)) != null) {
      return null;
    }
    final bytes = CapsuleCodec.encode(capsule);
    if (bytes.length <= request.maxCapsuleBytes) {
      return CrashCapsuleBuild(
        bytes,
        capsule.manifest.eligibility,
        checkpoint.kind,
      );
    }
  }
  return null;
}

/// The capsule of [journal] from [checkpoint] (not encoded or size-checked).
Capsule? crashCapsuleFrom(
  JournalContents journal,
  CrashCapsuleRequest request,
  Checkpoint checkpoint,
) {
  final h = journal.header;
  Map<String, Object?> obj(String key) =>
      (h[key] as Map?)?.cast<String, Object?>() ?? const {};
  final launch = journal.launch;
  final session = obj('session');
  final anchor =
      h['anchorMs'] as int? ?? launch?.t ?? journal.periodic?.t ?? checkpoint.t;
  final wallAtAnchor =
      session['wallClockAtAnchorMs'] as int? ??
      (checkpoint.wallClockMs + anchor - checkpoint.t);

  final templates = [
    for (final d in (h['dependencies'] as List?) ?? const [])
      CapsuleDependency.fromJson((d as Map).cast<String, Object?>()),
  ];
  final known = {for (final d in templates) d.id};
  final window = [
    for (final e in journal.events)
      if (e.seq > checkpoint.afterSeq &&
          (!InteractionTypes.isInteraction(e.type) ||
              known.contains(e.data['dep'])))
        e,
  ];
  final hasGap =
      checkpoint.kind == CheckpointKind.periodic &&
      journal.truncated &&
      window.isNotEmpty &&
      window.first.seq > checkpoint.afterSeq + 1;

  final dependencies = <CapsuleDependency>[];
  for (final d in templates) {
    final n = window
        .where(
          (e) =>
              e.data['dep'] == d.id && InteractionTypes.isInteraction(e.type),
        )
        .length;
    if (n == 0) continue;
    final json = d.toJson();
    json['stats'] = {...d.stats, 'events': n};
    dependencies.add(CapsuleDependency.fromJson(json));
  }

  final eligibility = EligibilityBuilder();
  final source = obj('source');
  if (source['gitSha'] == null) {
    eligibility.missing(
      'build.gitSha',
      'BUGCAPSULE_GIT_SHA was not set at build time',
    );
  } else if (source['dirty'] == true) {
    eligibility.missing(
      'build.gitSha',
      'built from a tree with uncommitted changes',
    );
  }
  final rewriteDropped = h['rewriteDropped'] as int? ?? 0;
  if (rewriteDropped > 0) {
    eligibility.missing(
      'events.redaction',
      '$rewriteDropped buffered events were dropped when redaction rules changed',
    );
  }
  if (hasGap) {
    eligibility.missing(
      'events.window',
      'the crash journal reached its size limit and dropped events after the checkpoint',
    );
  }
  final open = checkpoint.kind == CheckpointKind.periodic
      ? checkpoint.data['interactions']
      : null;
  final openList = open is Map ? open['open'] : null;
  if (openList is List &&
      openList.any((o) => o is Map && o['restorable'] != true)) {
    eligibility.missing(
      'interactions.restore',
      '${openList.length} connections or subscriptions were open at the '
          'periodic checkpoint and cannot be restored',
      blocking: true,
    );
  }
  final gaps = obj('eligibilityGaps')[checkpoint.kind.name];
  for (final g in gaps is List ? gaps : const []) {
    if (g is! Map) continue;
    final m = MissingDependency.fromJson(g.cast<String, Object?>());
    eligibility.missing(m.dependency, m.reason, blocking: m.blocking);
  }
  HttpBodies.describeEligibility(
    eligibility,
    RecordedWindow(
      checkpoint: checkpoint,
      events: window,
      droppedEvents: 0,
      hasGap: hasGap,
    ),
  );
  for (final d in dependencies) {
    if (d.gaps.isEmpty || !d.required) continue;
    eligibility.missing(
      'dependency.${d.id}',
      '${d.adapter}: ${[for (final g in d.gaps) g.count == null ? g.code : '${g.code}×${g.count}'].join(', ')}',
    );
  }
  eligibility.missing(
    'crash.native',
    'the app died in native code or was killed; replay re-runs the steps and '
        'checks for the same crash',
  );

  final events = rebaseOccurrences([for (final e in window) e.shift(anchor)]);
  final lastEventWall = window.isEmpty
      ? null
      : wallAtAnchor + window.last.t - anchor;
  final crashedAtMs = request.crashedAt?.millisecondsSinceEpoch;
  final lastT = events.isEmpty ? 0 : events.last.t;
  final failureT = crashedAtMs == null
      ? lastT
      : max(lastT, crashedAtMs - wallAtAnchor);
  final journalGapMs = crashedAtMs == null || lastEventWall == null
      ? null
      : max(0, crashedAtMs - lastEventWall);

  final templateIds = {for (final d in templates) 'interaction.${d.adapter}'};
  final capabilities = <String, String>{
    for (final e in obj('capabilities').entries)
      if (!templateIds.contains(e.key)) e.key: '${e.value}',
    for (final d in dependencies)
      'interaction.${d.adapter}': d.required ? 'supported' : 'partial',
  };
  final redaction = obj('redaction');
  final runtime = h['runtime'] as Map?;
  final failure = request.failure.record;
  return Capsule(
    manifest: CapsuleManifest(
      capsuleId: request.capsuleId,
      createdAt: request.createdAt,
      mode: CaptureMode.values.byName(h['mode'] as String),
      app: AppInfo.fromJson(obj('app')),
      gitSha: source['gitSha'] as String?,
      dirty: source['dirty'] as bool?,
      sdkName: obj('sdk')['name'] as String? ?? 'unknown',
      sdkVersion: obj('sdk')['version'] as String? ?? 'unknown',
      stateSchemaVersion: h['stateSchemaVersion'] as int? ?? 1,
      platform: PlatformInfo.fromJson(obj('platform')),
      session: SessionInfo(
        id: session['id'] as String,
        startedAt: DateTime.parse(session['startedAt'] as String),
        wallClockAtAnchorMs: wallAtAnchor,
        seed: session['seed'] as int,
        durationMs: max(0, failureT),
      ),
      failure: FailureRecord(
        kind: failure.kind,
        signature: failure.signature,
        type: failure.type,
        message: failure.message,
        stack: failure.stack,
        crash: failure.crash,
        t: max(0, failureT),
      ),
      eligibility: eligibility.build(),
      integrations: [
        for (final i in (h['integrations'] as List?) ?? const []) '$i',
      ],
      eventCount: events.length,
      droppedEvents: checkpoint.kind == CheckpointKind.launch
          ? 0
          : checkpoint.afterSeq,
      checkpointKind: checkpoint.kind,
      // The app's labels give up two slots for the crash labels, so the
      // capsule stays within CapsuleLimits.maxLabels.
      labels: {
        for (final e
            in obj('labels').entries
                .where((e) => e.key != 'source' && e.key != 'crash.mechanism')
                .take(CapsuleLimits.maxLabels - 2))
          e.key: '${e.value}',
        'source': 'crash_journal',
        'crash.mechanism': request.failure.mechanism.length > 2000
            ? request.failure.mechanism.substring(0, 2000)
            : request.failure.mechanism,
      },
      redactionKeys: [
        for (final k in (redaction['extraKeys'] as List?) ?? const []) '$k',
      ],
      redactionHeaders: [
        for (final k in (redaction['extraHeaders'] as List?) ?? const []) '$k',
      ],
      runtime: runtime == null
          ? null
          : RuntimeInfo.fromJson(runtime.cast<String, Object?>()),
      capabilities: capabilities,
      monitoring: request.monitoring,
      dependencies: dependencies,
      patch: h['patch'] == null
          ? null
          : CapsulePatchIdentity.fromJson(
              (h['patch'] as Map).cast<String, Object?>(),
            ),
      journalGapMs: journalGapMs,
    ),
    checkpoint: checkpoint.shift(anchor),
    events: events,
  );
}
