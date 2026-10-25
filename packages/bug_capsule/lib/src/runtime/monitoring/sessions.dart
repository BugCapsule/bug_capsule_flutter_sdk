import '../../core/core.dart';

/// Release health (monitoring-v1 §7): one session per foreground run.
///
/// * starts on launch in the foreground and when the app returns after
///   more than the background timeout (the old one ends `exited` at the
///   time it went to the background);
/// * counts error events; a crash (`fatal` event with `crashOnUnhandled`)
///   ends it `crashed`, and the next foreground starts a new one;
/// * every update is persisted, so a session still `ok` at the next launch
///   is reported `abnormal` if the app was in the foreground (killed: OOM,
///   watchdog, force quit) or `exited` if it was in the background.
class SessionTracker {
  SessionTracker({
    required this.release,
    required this.environment,
    required this.distinctId,
    required this.send,
    required this.persist,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String? release;
  final String environment;

  /// `user.id` when set, else the install id.
  final String Function() distinctId;

  /// Sends one `session` payload (each call is one update).
  final void Function(Map<String, Object?> payload) send;

  /// Saves the open session (null: none open) for the next launch.
  final void Function(Map<String, Object?>? state) persist;
  final DateTime Function() _now;

  _Session? _current;

  bool get active => _current != null;
  String? get sessionId => _current?.sid;

  /// The update for a session left open by the previous process, or null.
  Map<String, Object?>? recover(Map<String, Object?>? state) {
    if (state == null || state['status'] != 'ok') return null;
    try {
      final s = _Session.fromJson(state);
      final foreground = state['foreground'] != false;
      final backgroundAt = DateTime.tryParse('${state['backgroundAt']}');
      s.status = foreground ? 'abnormal' : 'exited';
      return s.payload(
        this,
        at: foreground ? s.lastUpdate : (backgroundAt ?? s.lastUpdate),
      );
    } catch (_) {
      return null;
    }
  }

  void start() {
    if (_current != null) end();
    final s = _current = _Session(uuidV4(), _now());
    _emit(s);
  }

  /// Ends the open session normally ([at] defaults to now).
  void end({DateTime? at}) {
    final s = _current;
    if (s == null) return;
    s.status = 'exited';
    _current = null;
    send(s.payload(this, at: at ?? _now()));
    persist(null);
  }

  /// Counts an error event. Returns the session update to send with it
  /// (in the same envelope), or null without an open session.
  Map<String, Object?>? onError({required bool crashed}) {
    final s = _current;
    if (s == null) return null;
    s.errors++;
    if (crashed) {
      s.status = 'crashed';
      _current = null;
      persist(null);
      return s.payload(this, at: _now());
    }
    final update = s.payload(this, at: _now());
    persist(s.state());
    return update;
  }

  void onBackground() {
    final s = _current;
    if (s == null || !s.foreground) return;
    s.foreground = false;
    s.backgroundAt = _now();
    persist(s.state());
  }

  void onForeground(Duration timeout) {
    final s = _current;
    if (s == null) return start();
    if (s.foreground) return;
    final at = s.backgroundAt ?? _now();
    if (_now().difference(at) >= timeout) {
      end(at: at);
      start();
    } else {
      s.foreground = true;
      s.backgroundAt = null;
      persist(s.state());
    }
  }

  void _emit(_Session s) {
    send(s.payload(this, at: _now()));
    persist(s.state());
  }
}

class _Session {
  _Session(this.sid, this.started) : lastUpdate = started;

  factory _Session.fromJson(Map<String, Object?> j) =>
      _Session(j['sid'] as String, DateTime.parse(j['started'] as String))
        ..seq = j['seq'] as int? ?? 0
        ..errors = j['errors'] as int? ?? 0
        ..did = j['did'] as String?
        ..lastUpdate =
            DateTime.tryParse('${j['lastUpdate']}') ??
            DateTime.parse(j['started'] as String);

  final String sid;
  final DateTime started;
  String? did;
  int seq = 0;
  int errors = 0;
  String status = 'ok';
  bool foreground = true;
  DateTime? backgroundAt;
  DateTime lastUpdate;

  Map<String, Object?> payload(SessionTracker t, {required DateTime at}) {
    final init = seq == 0;
    seq++;
    lastUpdate = at;
    did = t.distinctId();
    final seconds = at.difference(started).inMilliseconds / 1000;
    return {
      'sid': sid,
      'did': did,
      'seq': seq,
      'init': init,
      'started': isoTimestamp(started),
      'timestamp': isoTimestamp(at),
      'status': status,
      'errors': errors,
      'duration': seconds < 0 ? 0 : seconds,
      'release': ?t.release,
      'environment': t.environment,
      'runtime': 'flutter',
    };
  }

  Map<String, Object?> state() => {
    'sid': sid,
    'did': did,
    'seq': seq,
    'started': started.toUtc().toIso8601String(),
    'errors': errors,
    'status': status,
    'foreground': foreground,
    'backgroundAt': backgroundAt?.toUtc().toIso8601String(),
    'lastUpdate': lastUpdate.toUtc().toIso8601String(),
  };
}
