import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

import 'term.dart';

void printInspect(Capsule c, {int timeline = 40, bool json = false}) {
  if (json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(c.manifest.toJson()),
    );
    return;
  }
  final m = c.manifest;
  stdout
    ..writeln(bold('Capsule ${m.capsuleId}'))
    ..writeln(
      '  captured   ${m.createdAt.toLocal()}  ${dim('(${m.mode.name})')}',
    )
    ..writeln(
      '  app        ${m.app.name ?? m.app.id ?? ''} ${m.app.version}+${m.app.build}'
      '${m.app.flavor != null ? ' [${m.app.flavor}]' : ''}',
    )
    ..writeln(
      '  source     ${m.gitSha == null ? yellow('no git SHA') : m.gitSha!}'
      '${m.dirty == true ? yellow(' (dirty)') : ''}',
    )
    ..writeln(
      '  platform   ${m.platform.os} ${m.platform.osVersion}  '
      '${m.platform.screenWidth.toStringAsFixed(0)}×${m.platform.screenHeight.toStringAsFixed(0)} @${m.platform.pixelRatio}x'
      '${m.platform.dartVersion.isEmpty ? '' : '  ${dim('dart ${m.platform.dartVersion}')}'}',
    )
    ..writeln(
      '  runtime    ${m.runtimeName}${m.runtime?.version == null ? '' : ' ${m.runtime!.version}'}'
      '${m.runtime?.language == null ? '' : dim('  ${m.runtime!.language}')}'
      '${(m.runtime?.frameworks ?? const []).isEmpty ? '' : dim('  frameworks: ${m.runtime!.frameworks.join(', ')}')}'
      '${m.runtime == null ? dim('  (inferred from sdk.name)') : ''}',
    )
    ..writeln(
      '  sdk        ${m.sdkName} ${m.sdkVersion}  ${dim('integrations: ${m.integrations.join(', ')}')}',
    )
    ..writeln(
      '  session    ${(m.session.durationMs / 1000).toStringAsFixed(1)}s recorded, '
      '${m.eventCount} events${m.droppedEvents > 0 ? ', ${m.droppedEvents} evicted' : ''}, '
      'checkpoint: ${m.checkpointKind.name}',
    );
  if (m.labels.isNotEmpty) {
    stdout.writeln(
      '  labels     ${m.labels.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
    );
  }
  if (m.capabilities.isNotEmpty) {
    final limited = [
      for (final e in m.capabilities.entries)
        if (e.value != 'supported') '${e.key}=${e.value}',
    ];
    stdout.writeln(
      '  capability ${m.capabilities.length} declared'
      '${limited.isEmpty ? ', all supported' : dim('  not fully supported: ${limited.join(', ')}')}',
    );
  }

  if (m.dependencies.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln(
        '${bold('Dependencies')}  ${dim('spec v2: replay needs these adapters in the build')}',
      );
    for (final d in m.dependencies) {
      final coverage = switch (d.coverage) {
        DependencyCoverage.complete => green('complete'),
        DependencyCoverage.partial => yellow('partial'),
        DependencyCoverage.diagnostic => dim('diagnostic (capture only)'),
      };
      final tested = d.tested.entries
          .map((e) => '${e.key} ${e.value}')
          .join(', ');
      stdout.writeln(
        '  ${d.required ? '•' : dim('·')} ${d.id.padRight(12)} ${d.kind.padRight(16)} '
        '${d.adapter} ${d.adapterVersion} schema ${d.schema}  $coverage'
        '${tested.isEmpty ? '' : dim('  tested: $tested')}',
      );
      for (final g in d.gaps) {
        stdout.writeln(
          '      ${yellow('gap')} ${g.code}${g.count == null ? '' : ' ×${g.count}'}'
          '${g.detail == null ? '' : dim('  ${g.detail}')}',
        );
      }
    }
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
    stdout.writeln(
      '  ${missing.blocking ? red('✗') : yellow('•')} ${missing.dependency}: ${missing.reason}',
    );
  }

  stdout.writeln();
  final counts = <String, int>{};
  for (final ev in c.events) {
    counts.update(ev.type, (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln(
    '${bold('Events')}  ${counts.entries.map((e) => '${e.key} ${e.value}').join(' · ')}',
  );
  stdout.writeln(
    '${bold('Checkpoint')}  ${c.checkpoint.kind.name} at ${_t(c.checkpoint.t)}  '
    '${dim('data: ${c.checkpoint.data.keys.join(', ')}')}',
  );

  final http = c.events.where((e) => e.type == EventTypes.http).toList();
  if (http.isNotEmpty) {
    stdout.writeln();
    stdout.writeln(bold('Network'));
    for (final h in http) {
      final d = h.data;
      // `pending`: still in flight when the capsule was written; replay holds it open.
      final status = d['pending'] == true
          ? yellow('pending')
          : d['error'] != null
          ? red('ERR')
          : '${d['status']}';
      final sent = h.t - (d['durationMs'] as int? ?? 0);
      stdout.writeln(
        '  ${_t(sent).padLeft(8)}  ${'${d['method']}'.padRight(6)} '
        '${_path('${d['url']}').padRight(28)} $status  ${dim('${d['durationMs']}ms ${d['bodyEncoding']}')}',
      );
    }
  }

  final shown = c.events
      .where(
        (e) =>
            e.type != EventTypes.http &&
            !(e.type == EventTypes.pointer && e.data['phase'] == 'move'),
      )
      .toList();
  if (timeline > 0 && shown.isNotEmpty) {
    stdout.writeln();
    stdout.writeln(
      '${bold('Timeline')} ${dim('(last ${timeline < shown.length ? timeline : shown.length}, pointer moves hidden)')}',
    );
    for (final ev in shown.skip(
      shown.length > timeline ? shown.length - timeline : 0,
    )) {
      stdout.writeln(
        '  ${_t(ev.t).padLeft(8)}  ${ev.type.padRight(16)} ${_describe(ev)}',
      );
    }
  }
}

String _t(int ms) => '${(ms / 1000).toStringAsFixed(2)}s';

String _path(String url) {
  final uri = Uri.tryParse(url);
  return uri == null
      ? url
      : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
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
    EventTypes.riverpodAdd ||
    EventTypes.riverpodUpdate => '${d['key']} → ${d['state']}',
    EventTypes.riverpodDispose ||
    EventTypes.notifierCreate ||
    EventTypes.notifierChange ||
    EventTypes.getxCreate ||
    EventTypes.getxChange ||
    EventTypes.mobxCreate ||
    EventTypes.mobxChange => '${d['key']}',
    EventTypes.mobxObservable =>
      '${d['name']}${d.containsKey('value') ? ' = ${d['value']}' : ''}',
    EventTypes.mobxAction => '${d['name']}',
    EventTypes.mobxError => '${d['reaction']}: ${d['error']}',
    EventTypes.riverpodError => '${d['key']}: ${d['error']}',
    EventTypes.failure => red('${d['signature']}'),
    EventTypes.log => '${d['message']}',
    _ when InteractionTypes.isInteraction(e.type) => _interaction(e),
    _ => jsonEncode(d),
  };
}

/// One line per interaction event: its scope, then what the app saw
/// (payload values are shown only by mode and size).
String _interaction(BugCapsuleEvent e) {
  final d = e.data;
  String payload(String field) {
    final p = InteractionPayload.tryParse(d[field]);
    if (p == null) return '';
    final size = p.bytes == null ? '' : ' ${p.bytes}B';
    final mode = p.mode == PayloadMode.full ? '' : ' ${p.mode.name}';
    return dim(
      '[${p.kind ?? 'value'}$size$mode${p.replayable ? '' : ', not replayable'}]',
    );
  }

  return switch (e.type) {
    InteractionTypes.wsConnect =>
      '${d['conn']} ${d['url']}${(d['attempt'] as int? ?? 0) > 0 ? dim(' attempt ${d['attempt']}') : ''}',
    InteractionTypes.wsSend || InteractionTypes.wsMessage =>
      '${d['conn']} #${d['index']} ${payload('payload')}',
    InteractionTypes.wsClose =>
      '${d['conn']} by ${d['initiator']}${d['code'] == null ? '' : ' ${d['code']}'}',
    InteractionTypes.wsError => red(
      '${d['conn']} ${d['phase']}: ${(d['error'] as Map?)?['message']}',
    ),
    InteractionTypes.platformCall =>
      '${d['channel']} ${d['method'] ?? 'message'} ${d['dir'] == 'platform' ? '← platform' : '→ platform'} ${payload('args')}',
    InteractionTypes.platformError => red(
      '${d['channel']} ${d['call']} ${d['kind']}${d['code'] == null ? '' : ' ${d['code']}'}',
    ),
    InteractionTypes.nativeCall || InteractionTypes.nativeSubscribe =>
      '${d['dep']} ${d['operation']} ${payload('args')}',
    InteractionTypes.nativeError => red(
      '${d['dep']} ${d['op'] ?? d['sub']} ${d['code']}',
    ),
    _ =>
      '${d['dep']} ${d['conn'] ?? d['call'] ?? d['sub'] ?? d['op'] ?? ''} '
          '${payload('value')}${payload('payload')}',
  };
}
