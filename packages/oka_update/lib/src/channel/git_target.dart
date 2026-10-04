/// The git-branch publish target (ADR-0037 G-AC7): materialize a channel
/// tree as an orphan branch in a local git repository. Git is one
/// materialization of the channel, never the protocol (§2) — the branch
/// contents are exactly the `pointer.json` + manifests + artifacts tree,
/// readable by any file source (a clone, a worktree, a raw fetch).
library;

import 'dart:io';

import 'channel_source.dart';

/// The publish receipt.
class GitPublishReceipt {
  const GitPublishReceipt({
    required this.ok,
    required this.branch,
    this.commit,
    this.repo,
    this.files = 0,
    this.bytes = 0,
    this.reasons = const [],
  });

  final bool ok;
  final String branch;
  final String? commit;
  final String? repo;
  final int files;
  final int bytes;
  final List<String> reasons;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'branch': branch,
        if (commit != null) 'commit': commit,
        if (repo != null) 'repo': repo,
        'files': files,
        'bytes': bytes,
        'reasons': reasons,
      };
}

class _GitResult {
  const _GitResult(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

_GitResult _git(List<String> args, {String? cwd}) {
  final r = Process.runSync('git', args, workingDirectory: cwd);
  return _GitResult(
      r.exitCode, (r.stdout as String?) ?? '', (r.stderr as String?) ?? '');
}

/// Publishes [channelDir]'s tree as [branch] (orphan — the channel owns
/// its branch history, the repo's working tree is untouched) in the
/// local git repository at [repo]. Refuses (never force-touches) when
/// the branch is checked out in any worktree.
Future<GitPublishReceipt> publishChannelToGit({
  required String channelDir,
  required String repo,
  required String branch,
  String? message,
}) async {
  if (!Directory(channelDir).existsSync()) {
    return GitPublishReceipt(
        ok: false,
        branch: branch,
        repo: repo,
        reasons: ['channel dir missing: $channelDir']);
  }
  if (!Directory(repo).existsSync()) {
    return GitPublishReceipt(
        ok: false,
        branch: branch,
        repo: repo,
        reasons: ['repo directory missing: $repo']);
  }
  final inside = _git(['rev-parse', '--is-inside-work-tree'], cwd: repo);
  final isWorkTree = inside.code == 0 && inside.out.trim() == 'true';
  if (!isWorkTree) {
    // Bare repos and remote URLs have no work tree to attach to: publish
    // through a throwaway clone and push the branch (the push lane).
    final probe = _git(['ls-remote', repo, 'HEAD']);
    if (probe.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: [
            '$repo is neither a checked-out work tree nor a reachable git repo (bare or remote): ${probe.err.trim()}'
          ]);
    }
    return _publishViaClone(
        channelDir: channelDir, repo: repo, branch: branch, message: message);
  }

  final tmp = Directory.systemTemp.createTempSync('oka-channel-git-');
  var worktreeAdded = false;
  try {
    // Detached worktree at HEAD; needs at least one commit in the repo.
    final add = _git(['worktree', 'add', '--detach', tmp.path], cwd: repo);
    if (add.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: [
            'git worktree add failed: ${add.err.trim()} — the repo needs at least one commit'
          ]);
    }
    worktreeAdded = true;

    // Orphan branch; if it already exists, replace its content (the
    // channel branch is fully owned by the publisher).
    var orphan = _git(['checkout', '--orphan', branch], cwd: tmp.path);
    if (orphan.code != 0) {
      final del = _git(['branch', '-D', branch], cwd: tmp.path);
      if (del.code != 0) {
        return GitPublishReceipt(
            ok: false,
            branch: branch,
            repo: repo,
            reasons: [
              'cannot replace branch `$branch`: ${del.err.trim()} (is it checked out in another worktree?)'
            ]);
      }
      orphan = _git(['checkout', '--orphan', branch], cwd: tmp.path);
      if (orphan.code != 0) {
        return GitPublishReceipt(
            ok: false,
            branch: branch,
            repo: repo,
            reasons: ['orphan checkout failed: ${orphan.err.trim()}']);
      }
    }
    _git(['rm', '-rf', '--ignore-unmatch', '--quiet', '.'], cwd: tmp.path);
    for (final e in Directory(tmp.path).listSync()) {
      if (e.path.endsWith('.git')) continue;
      e.deleteSync(recursive: true);
    }
    _copyTree(Directory(channelDir), Directory(tmp.path));

    var files = 0;
    var bytes = 0;
    for (final f in Directory(tmp.path)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()) {
      files++;
      bytes += f.lengthSync();
    }
    _git(['add', '-A'], cwd: tmp.path);
    final commit = _git([
      '-c',
      'user.name=oka ship',
      '-c',
      'user.email=oka@ship.local',
      'commit',
      '--no-gpg-sign',
      '-m',
      message ?? 'oka ship: channel update',
    ], cwd: tmp.path);
    if (commit.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: ['git commit failed: ${commit.err.trim()}']);
    }
    final hash = _git(['rev-parse', 'HEAD'], cwd: tmp.path);
    return GitPublishReceipt(
        ok: true,
        branch: branch,
        commit: hash.out.trim(),
        repo: repo,
        files: files,
        bytes: bytes);
  } finally {
    if (worktreeAdded) {
      _git(['worktree', 'remove', '--force', tmp.path], cwd: repo);
    }
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

Future<GitPublishReceipt> _publishViaClone({
  required String channelDir,
  required String repo,
  required String branch,
  required String? message,
}) async {
  final tmp = Directory.systemTemp.createTempSync('oka-channel-clone-');
  try {
    final clone = _git(['clone', '--quiet', repo, tmp.path]);
    if (clone.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: ['git clone failed: ${clone.err.trim()}']);
    }
    var orphan = _git(['checkout', '--orphan', branch], cwd: tmp.path);
    if (orphan.code != 0) {
      _git(['branch', '-D', branch], cwd: tmp.path);
      orphan = _git(['checkout', '--orphan', branch], cwd: tmp.path);
      if (orphan.code != 0) {
        return GitPublishReceipt(
            ok: false,
            branch: branch,
            repo: repo,
            reasons: ['orphan checkout failed: ${orphan.err.trim()}']);
      }
    }
    _git(['rm', '-rf', '--ignore-unmatch', '--quiet', '.'], cwd: tmp.path);
    for (final e in Directory(tmp.path).listSync()) {
      if (e.path.endsWith('.git')) continue;
      e.deleteSync(recursive: true);
    }
    _copyTree(Directory(channelDir), Directory(tmp.path));
    var files = 0;
    var bytes = 0;
    for (final f in Directory(tmp.path)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()) {
      files++;
      bytes += f.lengthSync();
    }
    _git(['add', '-A'], cwd: tmp.path);
    final commit = _git([
      '-c', 'user.name=oka ship', //
      '-c', 'user.email=oka@ship.local', //
      'commit', //
      '--no-gpg-sign', //
      '-m', //
      message ?? 'oka ship: channel update',
    ], cwd: tmp.path);
    if (commit.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: ['git commit failed: ${commit.err.trim()}']);
    }
    // The publisher owns the branch: force replaces its history.
    final push = _git(
        ['push', '--force', 'origin', 'HEAD:refs/heads/$branch'],
        cwd: tmp.path);
    if (push.code != 0) {
      return GitPublishReceipt(
          ok: false,
          branch: branch,
          repo: repo,
          reasons: ['git push failed: ${push.err.trim()}']);
    }
    final hash = _git(['rev-parse', 'HEAD'], cwd: tmp.path);
    return GitPublishReceipt(
        ok: true,
        branch: branch,
        commit: hash.out.trim(),
        repo: repo,
        files: files,
        bytes: bytes);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

void _copyTree(Directory from, Directory to) {
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(from.path.length + 1);
    final target = '${to.path}/$rel';
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}

/// Reads a branch of a local repo into a plain directory (the client
/// side of the git materialization — a checkout is just a file tree).
Future<String> checkoutChannelBranch({
  required String repo,
  required String branch,
  required String into,
}) async {
  final dir = Directory(into);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final tarDir = Directory.systemTemp.createTempSync('oka-channel-read-');
  final tarFile = '${tarDir.path}/c.tar';
  try {
    final archive = _git(
        ['archive', '--format=tar', '--output', tarFile, branch],
        cwd: repo);
    if (archive.code != 0) {
      throw ChannelSourceException(
          'git archive $branch failed: ${archive.err.trim()}');
    }
    final untar =
        Process.runSync('tar', ['-xf', tarFile, '-C', into]);
    if (untar.exitCode != 0) {
      throw ChannelSourceException(
          'tar extract failed: ${(untar.stderr as String?)?.trim()}');
    }
  } finally {
    tarDir.deleteSync(recursive: true);
  }
  return into;
}
