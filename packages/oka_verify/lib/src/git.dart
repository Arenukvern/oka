/// The git facts the verify lane needs (ADR-0048): which files changed,
/// and which revision the run belongs to.
///
/// Both queries are bounded: a git that hangs (a lock, a network
/// filesystem) must not hang the agent loop, so the queries run through
/// oka's bounded process substrate and a timeout is a reported "unknown",
/// never a silent empty answer.
library;

import 'package:oka_core/oka_core.dart';

/// The changed files of the workspace, as absolute paths.
///
/// Changed means "differs from HEAD" plus "not tracked yet" — the two
/// sets together are what a developer means by "what I am working on".
Future<List<String>> gitChangedFiles(
  String repoRoot, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final diff = await _git(['diff', '--name-only', 'HEAD'], repoRoot, timeout);
  // `-uall` lists every untracked file individually; the default collapses
  // an untracked directory into one entry, which the coverage analysis
  // cannot attribute to a suite.
  final status = await _git(
    ['status', '--porcelain', '-uall'],
    repoRoot,
    timeout,
  );
  final names = <String>[
    ...diff.split('\n'),
    for (final line in status.split('\n'))
      if (line.startsWith('?? ')) line.substring(3).trim(),
  ];
  final paths = <String>[];
  for (final name in names) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    paths.add(trimmed.startsWith('/') ? trimmed : '$repoRoot/$trimmed');
  }
  return paths;
}

/// The short git revision of the workspace, or `unknown` when git cannot
/// answer (a non-git workspace is a legitimate input).
Future<String> gitRevision(
  String repoRoot, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final out = await _git(
    ['rev-parse', '--short=10', 'HEAD'],
    repoRoot,
    timeout,
  );
  final trimmed = out.trim();
  return trimmed.isEmpty ? 'unknown' : trimmed;
}

Future<String> _git(
  List<String> arguments,
  String repoRoot,
  Duration timeout,
) async {
  final result = await runBoundedProcess(
    'git',
    arguments,
    workingDirectory: repoRoot,
    timeout: timeout,
    maxCapturedBytes: 4 * 1024 * 1024,
  );
  if (result.cause != BoundedRunCause.exited) return '';
  return result.stdout;
}
