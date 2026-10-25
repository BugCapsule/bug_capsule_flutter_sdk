// Generates the cross-language conformance fixtures in
// `spec/fixtures/conformance/` from this (reference) implementation.
//
//   dart run tool/generate_conformance.dart          # rewrite the fixtures
//   dart run tool/generate_conformance.dart --check  # exit 1 if they differ
//
// The Android, iOS and web SDKs run the same files in their test suites, so
// request keys, failure signatures, redaction and verdicts agree across
// runtimes. `test/conformance_test.dart` fails when the files are stale.
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/core/core.dart';

import 'conformance_cases.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  final dir = Directory('${_specRoot()}/fixtures/conformance');
  var stale = false;
  for (final entry in buildConformanceFixtures().entries) {
    final file = File('${dir.path}/${entry.key}');
    final text = '${const JsonEncoder.withIndent('  ').convert(entry.value)}\n';
    if (check) {
      if (!file.existsSync() || file.readAsStringSync() != text) {
        stderr.writeln('stale: ${file.path}');
        stale = true;
      }
    } else {
      file
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
      stdout.writeln('wrote ${file.path}');
    }
  }
  if (stale) exit(1);
}

String _specRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final spec = Directory('${dir.path}/spec');
    if (File('${spec.path}/capsule-v1.md').existsSync()) return spec.path;
    dir = dir.parent;
  }
  throw StateError('spec/ not found above ${Directory.current.path}');
}

/// Exposed so the test can compare without touching the files.
Map<String, Object?> buildConformanceFixtures() => {
  'request-keys.json': _requestKeys(),
  'signatures.json': _signatures(),
  'redaction.json': _redaction(),
  'verdicts.json': _verdicts(),
};

Map<String, Object?> _header(String what) => {
  'format': 'bugcapsule.conformance',
  'version': 1,
  'generatedBy': 'packages/bug_capsule/tool/generate_conformance.dart',
  'description': what,
};

Map<String, Object?> _requestKeys() {
  final cases = <Map<String, Object?>>[];
  for (final c in requestKeyCases) {
    final rules = [
      for (final r
          in (c['rules'] as List? ?? const []).cast<Map<String, Object?>>())
        EndpointRule(
          r['method'] as String,
          r['path'] as String,
          ignoreQuery: {
            ...(r['ignoreQuery'] as List? ?? const []).cast<String>(),
          },
          ignoreBodyFields: {
            ...(r['ignoreBodyFields'] as List? ?? const []).cast<String>(),
          },
          matchBodyFields: r['matchBodyFields'] == null
              ? null
              : {...(r['matchBodyFields'] as List).cast<String>()},
        ),
    ];
    final builder = RequestKeyBuilder(
      rules: rules,
      globalIgnoreQuery: c.containsKey('globalIgnoreQuery')
          ? {...(c['globalIgnoreQuery'] as List).cast<String>()}
          : const {'_', 'ts', 'timestamp', 'nonce', 'cachebust'},
      globalIgnoreBodyFields: {
        ...(c['globalIgnoreBodyFields'] as List? ?? const []).cast<String>(),
      },
    );
    final redactor = Redactor(
      extraKeys: (c['redactKeys'] as List? ?? const []).cast<String>(),
    );
    var uri = Uri.parse(c['url'] as String);
    var body = c['body'];
    if (c['redact'] == true) {
      uri = redactor.redactUri(uri);
      if (body != null) {
        body = redactor.redactJson(body is String ? _tryJson(body) : body);
      }
    }
    cases.add({
      ...c,
      'expectedKey': builder.keyFor(c['method'] as String, uri, body),
    });
  }
  return {
    ..._header(
      'Request keys (spec capsule-v1 "Network matching"). Inputs: method, url, body (a JSON '
      'value, or a string that is parsed as JSON when it is valid JSON and hashed as text '
      'otherwise; null = no body), rules, globalIgnoreQuery (default: _, ts, timestamp, nonce, '
      'cachebust), globalIgnoreBodyFields. With "redact": true the URL and body go through '
      'the default redactor (plus redactKeys) first, as capture and replay do.',
    ),
    'cases': cases,
  };
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return s;
  }
}

Map<String, Object?> _signatures() => {
  ..._header(
    'Failure signatures: <kind>:<type>:<normalized first line of the message>.',
  ),
  'cases': [
    for (final c in signatureCases)
      {
        ...c,
        'expected': FailureSignature.compute(
          FailureKind.values.byName(c['kind'] as String),
          c['type'] as String,
          c['message'] as String,
        ),
      },
  ],
};

Map<String, Object?> _redaction() {
  final r = Redactor(
    extraKeys: const ['loyaltyId'],
    extraHeaders: const ['x-tenant'],
  );
  return {
    ..._header(
      'Redaction with the default rules plus extraKeys ["loyaltyId"] and extraHeaders '
      '["x-tenant"]. redactUrl: "params" lists the decoded query parameters of the output in '
      'order; implementations must match them (and should match "output" exactly).',
    ),
    'extraKeys': ['loyaltyId'],
    'extraHeaders': ['x-tenant'],
    'placeholder': Redactor.placeholder,
    'keys': [
      for (final k in redactionKeyCases)
        {
          'key': k,
          'sensitive': r.isSensitiveKey(k),
          'sensitiveQuery': r.isSensitiveQueryKey(k),
        },
    ],
    'headers': [
      for (final h in redactionHeaderCases)
        {'name': h, 'sensitive': r.isSensitiveHeader(h)},
    ],
    'scrubText': [
      for (final t in scrubTextCases) {'input': t, 'output': r.scrubText(t)},
    ],
    'redactUrl': [
      for (final u in redactUrlCases)
        () {
          final out = r.redactUrl(u);
          final parsed = Uri.parse(out);
          return {
            'input': u,
            'output': out,
            'params': [
              for (final e in parsed.queryParametersAll.entries)
                for (final v in e.value) [e.key, v],
            ],
          };
        }(),
    ],
    'redactHeaders': [
      for (final h in redactHeadersCases)
        {'input': h, 'output': r.redactHeaders(h)},
    ],
    'redactJson': [
      for (final j in redactJsonCases) {'input': j, 'output': r.redactJson(j)},
    ],
    'redactText': [
      for (final t in redactTextCases)
        {
          ...t,
          'output': r.redactText(
            t['id'] as String,
            t['value'] as String,
            sensitive: t['sensitive'] as bool? ?? false,
          ),
        },
    ],
  };
}

Map<String, Object?> _verdicts() {
  final cases = <Map<String, Object?>>[];
  for (final c in verdictCases) {
    final reports = [
      for (final r in (c['reports'] as List).cast<Map<String, Object?>>())
        ReplayReport(
          outcome: ReplayOutcome.parse(r['outcome'] as String),
          attempt: 1,
          durationMs: 100,
          strategy: ReplayStrategy.auto,
          expectedSignature: r['expectedSignature'] as String?,
          eventsDispatched: r['eventsDispatched'] as int? ?? 0,
          eventsExpected: r['eventsExpected'] as int?,
          divergences: [
            for (final d
                in (r['divergences'] as List? ?? const []).cast<String>())
              Divergence(d, 'x'),
          ],
          otherFailures: [
            for (final f
                in (r['otherFailures'] as List? ?? const []).cast<String>())
              FailureRecord(
                kind: FailureKind.exception,
                signature: f,
                type: 'E',
                message: '',
                t: 0,
              ),
          ],
          message: r['message'] as String?,
        ),
    ];
    final e = evaluateRun(
      RunKind.values.byName(c['kind'] as String),
      c['requested'] as int,
      reports,
    );
    cases.add({
      ...c,
      'verdict': e.verdict.name,
      'wire': e.verdict.wire,
      'exitCode': e.exitCode,
      'validAttempts': e.validAttempts,
      'attemptStatuses': [for (final a in e.attempts) a.status.name],
    });
  }
  return {
    ..._header(
      'Attempt classification and batch verdicts (lib/src/core/verdict.dart evaluateRun). '
      'Divergence types not listed in "expectedDivergences" are material.',
    ),
    'expectedDivergences': DivergencePolicy.expected.toList()..sort(),
    'cases': cases,
  };
}
