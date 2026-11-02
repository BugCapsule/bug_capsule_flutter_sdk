import 'dart:io';

class GitInfo {
  const GitInfo({required this.root, required this.head, required this.dirty});
  final String root;
  final String head;
  final bool dirty;
}

Future<String?> _git(String dir, List<String> args) async {
  final res = await Process.run('git', ['-C', dir, ...args]);
  return res.exitCode == 0 ? '${res.stdout}'.trim() : null;
}

Future<GitInfo?> gitInfo(String dir) async {
  final root = await _git(dir, ['rev-parse', '--show-toplevel']);
  if (root == null) return null;
  final head = await _git(dir, ['rev-parse', 'HEAD']);
  if (head == null) return null;
  final status = await _git(dir, ['status', '--porcelain']);
  return GitInfo(root: root, head: head, dirty: (status ?? '').isNotEmpty);
}

Future<bool> commitExists(String dir, String sha) async =>
    await _git(dir, ['cat-file', '-e', '$sha^{commit}']) != null;

/// Creates (or reuses) a detached worktree of [sha] and returns the path of
/// [projectDir] inside it.
Future<String> pinnedProjectDir(
  GitInfo git,
  String projectDir,
  String sha,
) async {
  final short = sha.substring(0, sha.length < 12 ? sha.length : 12);
  // Under the user's own home, not the shared temp directory: another local
  // user could otherwise create the directory first and have their code
  // built and run as this user (C3).
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) throw StateError('no home directory for pinned worktrees');
  final repo = git.root.hashCode.toUnsigned(32).toRadixString(16);
  final parent = Directory('$home/.bugcapsule/pins');
  parent.createSync(recursive: true);
  if (!Platform.isWindows) Process.runSync('chmod', ['700', parent.path]);
  final worktree = '${parent.path}/$repo-$short';
  if (Directory(worktree).existsSync()) {
    // Reuse only a worktree of this repository checked out at [sha].
    final head = await Process.run('git', ['-C', worktree, 'rev-parse', 'HEAD']);
    final common = await Process.run('git', [
      '-C',
      worktree,
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ]);
    final ours = await Process.run('git', [
      '-C',
      git.root,
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ]);
    if (head.exitCode != 0 ||
        '${head.stdout}'.trim() != sha ||
        '${common.stdout}'.trim() != '${ours.stdout}'.trim()) {
      throw StateError(
        '$worktree exists but is not this repository at ${sha.substring(0, 12)}; remove it and retry',
      );
    }
  } else {
    final res = await Process.run('git', [
      '-C',
      git.root,
      'worktree',
      'add',
      '--detach',
      worktree,
      sha,
    ]);
    if (res.exitCode != 0) {
      throw StateError('git worktree add failed: ${res.stderr}');
    }
  }
  final absProject = Directory(projectDir).absolute.resolveSymbolicLinksSync();
  final absRoot = Directory(git.root).resolveSymbolicLinksSync();
  final relative = absProject.length > absRoot.length
      ? absProject.substring(absRoot.length + 1)
      : '';
  return relative.isEmpty ? worktree : '$worktree/$relative';
}
