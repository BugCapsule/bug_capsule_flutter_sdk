import 'dart:io';

final bool _color = stdout.supportsAnsiEscapes && Platform.environment['NO_COLOR'] == null;

String _wrap(String code, String s) => _color ? '\x1B[${code}m$s\x1B[0m' : s;
String bold(String s) => _wrap('1', s);
String dim(String s) => _wrap('2', s);
String red(String s) => _wrap('31', s);
String green(String s) => _wrap('32', s);
String yellow(String s) => _wrap('33', s);
String cyan(String s) => _wrap('36', s);

/// One-line progress indicator: "label…" then "label ✓ 12.3s".
class Progress {
  Progress(this.label) {
    stdout.write('$label… ');
  }

  final String label;
  final Stopwatch _sw = Stopwatch()..start();

  String get _elapsed => '${(_sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

  void done([String note = '']) => stdout.writeln('${green('✓')} ${dim(_elapsed)} $note');
  void fail([String note = '']) => stdout.writeln('${red('✗')} ${dim(_elapsed)} $note');
}

String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;
