import 'dart:async';
import 'dart:io';

import 'backend_client.dart';
import 'term.dart';

/// The hosted API, used when neither `--url`, BUGCAPSULE_URL nor a saved
/// login names another backend.
const defaultBackendUrl = 'https://api.bugcapsule.com';

/// Why a browser sign-in ended without a token. [toString] is what the
/// person reads.
class BrowserLoginException implements Exception {
  BrowserLoginException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What an approved sign-in answers: a personal token bound to one project.
class BrowserLoginResult {
  BrowserLoginResult({
    required this.token,
    required this.expiresAt,
    required this.projectId,
    required this.projectName,
    required this.email,
  });

  final String token;
  final String expiresAt;
  final String projectId;
  final String projectName;
  final String email;
}

/// Loopback, and the Android emulator's alias for this machine (same rule
/// as the SDKs' connection tokens; the CLI doesn't import the Flutter runtime).
bool _localDevelopmentHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h == '::1' ||
      h == '[::1]' ||
      h == '10.0.2.2' ||
      RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(h);
}

/// Whether the sign-in page the server sent may be opened automatically:
/// https (http only on a local development host), no user info, and the same
/// site as the API ([api] `api.example.com` allows `app.example.com`).
bool isTrustedLoginPage(Uri? page, Uri api) {
  if (page == null || !page.hasAuthority || page.userInfo.isNotEmpty) {
    return false;
  }
  if (page.scheme == 'http') {
    return _localDevelopmentHost(page.host) && _localDevelopmentHost(api.host);
  }
  if (page.scheme != 'https') return false;
  String site(String host) {
    final labels = host.toLowerCase().split('.');
    return labels.length <= 2
        ? labels.join('.')
        : labels.sublist(labels.length - 2).join('.');
  }

  return site(page.host) == site(api.host);
}

/// Opens [url] in the default browser; false when nothing could.
Future<bool> openInBrowser(String url) async {
  final (exe, args) = Platform.isMacOS
      ? ('open', [url])
      : Platform.isWindows
      ? ('rundll32', ['url.dll,FileProtocolHandler', url])
      : ('xdg-open', [url]);
  try {
    final r = await Process.run(exe, args).timeout(const Duration(seconds: 10));
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

/// This machine's name as the dashboard shows it: printable and short.
String clientName() {
  String name;
  try {
    name = Platform.localHostname;
  } on Object {
    name = '';
  }
  name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (name.endsWith('.local')) name = name.substring(0, name.length - 6);
  if (name.isEmpty) return 'BugCapsule CLI';
  return name.length > 60 ? name.substring(0, 60) : name;
}

/// `bugcapsule login` without a token: like `firebase login` or
/// `gh auth login`. The backend starts a request; the person checks the code
/// in the browser and approves it for one project; the CLI polls until the
/// backend answers a personal token (bcp_). Nothing is copied by hand.
class BrowserLogin {
  BrowserLogin({
    required this.url,
    this.launch = true,
    Future<bool> Function(String url)? open,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    StringSink? out,
  }) : _open = open ?? openInBrowser,
       _sleep = sleep ?? Future<void>.delayed,
       _now = now ?? DateTime.now,
       _out = out ?? stdout;

  /// Backend URL.
  final String url;

  /// False with `--no-browser`: only print the address.
  final bool launch;

  final Future<bool> Function(String url) _open;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final StringSink _out;

  Future<BrowserLoginResult> run() async {
    final client = BackendClient(Credentials(url: url));
    final Map<String, Object?> started;
    try {
      started = await client.startBrowserLogin(clientName());
    } on ApiException catch (e) {
      if (e.status == 404) {
        throw BrowserLoginException(
          'This BugCapsule server doesn’t offer browser sign-in yet. Issue a personal token in the dashboard '
          '(Project Settings › Keys & CLI access) and run `bugcapsule login --url $url --token <token>`.',
        );
      }
      throw BrowserLoginException(e.detail.isEmpty ? '$e' : e.detail);
    } on SocketException catch (e) {
      throw BrowserLoginException(
        'Can’t reach $url (${e.message}). Check the address, or pass --url.',
      );
    }

    final deviceCode = started['deviceCode']! as String;
    final userCode = started['userCode']! as String;
    final page = started['verificationUrlComplete']! as String;
    final expiresAt = DateTime.parse(started['expiresAt']! as String);
    var interval = Duration(
      seconds: (started['interval'] as num?)?.toInt() ?? 2,
    );

    _out
      ..writeln('Sign in to BugCapsule in your browser.')
      ..writeln()
      ..writeln('  Your code: ${bold(userCode)}')
      ..writeln('  ${launch ? 'Opening' : 'Open'} ${cyan(page)}')
      ..writeln();
    final pageUri = Uri.tryParse(page);
    if (launch && !isTrustedLoginPage(pageUri, Uri.parse(url))) {
      _out.writeln(
        yellow(
          'Not opening that address automatically: it is not an https page of '
          '${Uri.parse(url).host}. Open it yourself only if you recognise it.',
        ),
      );
    } else if (launch && !await _open(page)) {
      _out.writeln(
        yellow(
          'Couldn’t open a browser here: open the address above on any device.',
        ),
      );
    }
    _out.writeln(
      dim(
        'Check the code in the browser matches, then approve. Waiting… (Ctrl-C to cancel)',
      ),
    );

    while (true) {
      await _sleep(interval);
      if (_now().isAfter(expiresAt)) break;
      final Map<String, Object?> r;
      try {
        r = await client.pollBrowserLogin(deviceCode);
      } on SocketException {
        continue; // A dropped connection: try again until the request expires.
      } on ApiException catch (e) {
        if (e.status == 429) {
          interval *= 2;
          continue;
        }
        if (e.status >= 500 && e.status != 503) continue;
        throw BrowserLoginException(e.detail.isEmpty ? '$e' : e.detail);
      }
      switch (r['status']) {
        case 'pending':
          continue;
        case 'approved':
          final project = (r['project']! as Map).cast<String, Object?>();
          final user = (r['user']! as Map).cast<String, Object?>();
          return BrowserLoginResult(
            token: r['token']! as String,
            expiresAt: r['expiresAt']! as String,
            projectId: project['id']! as String,
            projectName: project['name']! as String,
            email: user['email']! as String,
          );
        case 'denied':
          throw BrowserLoginException('Sign-in was canceled in the browser.');
        default:
          break;
      }
      break;
    }
    throw BrowserLoginException(
      'The sign-in request expired before it was approved. Run `bugcapsule login` again.',
    );
  }
}
