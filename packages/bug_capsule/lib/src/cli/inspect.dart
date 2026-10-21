import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

import 'term.dart';

void printInspect(Capsule c, {int timeline = 40, bool json = false}) {
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(c.manifest.toJson()));
    return;
  }
  final m = c.manifest;
  stdout
    ..writeln(bold('Capsule ${m.capsuleId}'))
    ..writeln('  captured   ${m.createdAt.toLocal()}  ${dim('(${m.mode.name})')}')
    ..writeln('  app        ${m.app.name ?? m.app.id ?? ''} ${m.app.version}+${m.app.build}'
        '${m.app.flavor != null ? ' [${m.app.flavor}]' : ''}')
    ..writeln('  source     ${m.gitSha == null ? yellow('no git SHA') : m.gitSha!}'
        '${m.dirty == true ? yellow(' (dirty)') : ''}')
    ..writeln('  platform   ${m.platform.os} ${m.platform.osVersion}  '
        '${m.platform.screenWidth.toStringAsFixed(0)}×${m.platform.screenHeight.toStringAsFixed(0)} @${m.platform.pixelRatio}x'
        '${m.platform.dartVersion.isEmpty ? '' : '  ${dim('dart ${m.platform.dartVersion}')}'}')
    ..writeln('  runtime    ${m.runtimeName}${m.runtime?.version == null ? '' : ' ${m.runtime!.version}'}'
        '${m.runtime?.language == null ? '' : dim('  ${m.runtime!.language}')}'
        '${(m.runtime?.frameworks ?? const []).isEmpty ? '' : dim('  frameworks: ${m.runtime!.frameworks.join(', ')}')}'
        '${m.runtime == null ? dim('  (inferred from sdk.name)') : ''}')
    ..writeln('  sdk        ${m.sdkName} ${m.sdkVersion}  ${dim('integrations: ${m.integrations.join(', ')}')}')
    ..writeln('  session    ${(m.session.durationMs / 1000).toStringAsFixed(1)}s recorded, '
        '${m.eventCount} events${m.droppedEvents > 0 ? ', ${m.droppedEvents} evicted' : ''}, '
        'checkpoint: ${m.checkpointKind.name}');
  if (m.labels.isNotEmpty) {
    stdout.writeln('  labels     ${m.labels.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  }
  if (m.capabilities.isNotEmpty) {
    final limited = [
      for (final e in m.capabilities.entries)
        if (e.value != 'supported') '${e.key}=${e.value}',
    ];
    stdout.writeln('  capability ${m.capabilities.length} declared'
        '${limited.isEmpty ? ', all supported' : dim('  not fully supported: ${limited.join(', ')}')}');
  }

  stdout.writeln();
  final f = m.failure;
  if (f == null) {
    stdout.writeln('${bold('Failure')}  ${yellow('none (manual capture)')}');
  } else {
    stdout
      ..writeln('${bold('Failure')}  ${red(f.signature)}')
      ..writeln('  at ${_t(f.t)}  ${f.message.split('\n').first}');
  }

  final e = m.eligibility;
  final color = switch (e.status) {
    EligibilityStatus.eligible => green,
    EligibilityStatus.partial => yellow,
    EligibilityStatus.ineligible => red,
  };
  stdout.writeln('${bold('Eligibility')}  ${color(e.status.name)}');
  for (final missing in e.missing) {
    stdout.writeln('  ${missing.blocking ? red('✗') : yellow('•')} ${missing.dependency}: ${missing.reason}');
  }

  stdout.writeln();
  final counts = <String, int>{};
  for (final ev in c.events) {
    counts.update(ev.type, (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln('${bold('Events')}  ${counts.entries.map((e) => '${e.key} ${e.value}').join(' · ')}');
  stdout.writeln('${bold('Checkpoint')}  ${c.checkpoint.kind.name} at ${_t(c.checkpoint.t)}  '
      '${dim('data: ${c.checkpoint.data.keys.join(', ')}')}');

  final http = c.events.where((e) => e.type == EventTypes.http).toList();
  if (http.isNotEmpty) {
    stdout.writeln();
    stdout.writeln(bold('Network'));
    for (final h in http) {
      final d = h.data;
      final status = d['error'] != null ? red('ERR') : '${d['status']}';
      final sent = h.t - (d['durationMs'] as int? ?? 0);
      stdout.writeln('  ${_t(sent).padLeft(8)}  ${'${d['method']}'.padRight(6)} '
          '${_path('${d['url']}').padRight(28)} $status  ${dim('${d['durationMs']}ms ${d['bodyEncoding']}')}');
    }
  }

  final shown = c.events.where((e) => e.type != EventTypes.http && !(e.type == EventTypes.pointer && e.data['phase'] == 'move')).toList();
  if (timeline > 0 && shown.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('${bold('Timeline')} ${dim('(last ${timeline < shown.length ? timeline : shown.length}, pointer moves hidden)')}');
    for (final ev in shown.skip(shown.length > timeline ? shown.length - timeline : 0)) {
      stdout.writeln('  ${_t(ev.t).padLeft(8)}  ${ev.type.padRight(11)} ${_describe(ev)}');
    }
  }
}

String _t(int ms) => '${(ms / 1000).toStringAsFixed(2)}s';

String _path(String url) {
  final uri = Uri.tryParse(url);
  return uri == null ? url : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
}

String _describe(BugCapsuleEvent e) {
  final d = e.data;
  return switch (e.type) {
    EventTypes.pointer => '${d['phase']} (${d['x']}, ${d['y']})',
    EventTypes.action => '${d['id']}',
    EventTypes.text => '${d['id']} = "${d['value']}"',
    EventTypes.lifecycle => '${d['state']}',
    EventTypes.route => '${d['location']}',
    EventTypes.blocEvent => '${d['key']} ← ${d['event']}',
    EventTypes.blocState => '${d['key']} → ${d['state']}',
    EventTypes.blocCreate || EventTypes.blocClose => '${d['key']}',
    EventTypes.blocError => '${d['key']}: ${d['error']}',
    EventTypes.riverpodAdd || EventTypes.riverpodUpdate => '${d['key']} → ${d['state']}',
    EventTypes.riverpodDispose ||
    EventTypes.notifierCreate ||
    EventTypes.notifierChange ||
    EventTypes.getxCreate ||
    EventTypes.getxChange ||
    EventTypes.mobxCreate ||
    EventTypes.mobxChange =>
      '${d['key']}',
    EventTypes.mobxObservable => '${d['name']}${d.containsKey('value') ? ' = ${d['value']}' : ''}',
    EventTypes.mobxAction => '${d['name']}',
    EventTypes.mobxError => '${d['reaction']}: ${d['error']}',
    EventTypes.riverpodError => '${d['key']}: ${d['error']}',
    EventTypes.failure => red('${d['signature']}'),
    EventTypes.log => '${d['message']}',
    _ => jsonEncode(d),
  };
}
