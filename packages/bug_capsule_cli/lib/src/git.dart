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
Future<String> pinnedProjectDir(GitInfo git, String projectDir, String sha) async {
  final short = sha.substring(0, sha.length < 12 ? sha.length : 12);
  final worktree = '${Directory.systemTemp.path}/bugcapsule-pin-$short';
  if (!Directory(worktree).existsSync()) {
    final res = await Process.run(
        'git', ['-C', git.root, 'worktree', 'add', '--detach', worktree, sha]);
    if (res.exitCode != 0) throw StateError('git worktree add failed: ${res.stderr}');
  }
  final absProject = Directory(projectDir).absolute.resolveSymbolicLinksSync();
  final absRoot = Directory(git.root).resolveSymbolicLinksSync();
  final relative = absProject.length > absRoot.length ? absProject.substring(absRoot.length + 1) : '';
  return relative.isEmpty ? worktree : '$worktree/$relative';
}
