import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Injectable gitignore-checker seam (ADR-0014 repo hygiene).
///
/// Returns true when [absolutePath] is ignored by version control. Tests
/// inject a plain function; production defaults to [isIgnoredByGitignore].
typedef GitignoreChecker = bool Function(String absolutePath);

/// Outcome of the credential repo-hygiene check (ADR-0014).
@immutable
class RepoHygieneReport {
  const RepoHygieneReport({
    required this.credentialPath,
    required this.projectPath,
    required this.insideProject,
    required this.ok,
    required this.message,
    this.isIgnored,
  });

  /// Resolved credential file path that was checked.
  final String credentialPath;

  /// Project root the check ran against.
  final String projectPath;

  /// Whether the credential lives inside the project (outside → not
  /// checked, and not the repo's problem).
  final bool insideProject;

  /// Whether the credential file is ignored by version control. Null when
  /// not applicable (file outside the project, or the file does not exist
  /// yet).
  final bool? isIgnored;

  /// Pass/fail of the check: files outside the project pass trivially; a
  /// tracked credential file inside the project fails.
  final bool ok;

  /// Human-readable outcome, with the fix on failure.
  final String message;

  /// Doctor-ready line (✅ / ⚠️ / ℹ️ prefix).
  String get doctorLine =>
      '${ok ? (insideProject ? '✅' : 'ℹ️ ') : '⚠️ '} $message';
}

/// Repo-hygiene check (ADR-0014): a credential file resolved **inside the
/// project** must be gitignored — oka checks and warns.
///
/// Pure over the [isIgnored] seam; inject a checker in tests. The default
/// ([isIgnoredByGitignore]) parses the project's `.gitignore`. When no
/// checker is injected and no `.gitignore` exists, the file is treated as
/// not ignored (fail-closed).
RepoHygieneReport checkCredentialRepoHygiene({
  required final String credentialPath,
  required final String projectPath,
  final GitignoreChecker? isIgnored,
}) {
  final inside = p.isWithin(
    p.normalize(projectPath),
    p.normalize(credentialPath),
  );
  if (!inside) {
    return RepoHygieneReport(
      credentialPath: credentialPath,
      projectPath: projectPath,
      insideProject: false,
      ok: true,
      message:
          'credential $credentialPath is outside the project — nothing to '
          'check',
    );
  }
  final ignored = isIgnored?.call(credentialPath) ??
      isIgnoredByGitignore(credentialPath, projectPath: projectPath);
  return RepoHygieneReport(
    credentialPath: credentialPath,
    projectPath: projectPath,
    insideProject: true,
    ok: ignored,
    isIgnored: ignored,
    message: ignored
        ? 'credential $credentialPath is gitignored'
        : 'credential file resolved inside the project is NOT gitignored: '
            '$credentialPath — add it to .gitignore (ADR-0014 repo '
            'hygiene: secrets must never enter git history)',
  );
}

/// Default [GitignoreChecker]: parses `<projectPath>/.gitignore` (plus
/// `.git/info/exclude` when present) and matches [absolutePath].
///
/// Supports the common patterns: blank/comment lines, `!` negation,
/// trailing `/` (directory-only), leading `/` anchoring, `*` / `?` /
/// `**` globs, and patterns containing `/` (root-anchored). Last matching
/// pattern wins (standard gitignore semantics).
bool isIgnoredByGitignore(
  final String absolutePath, {
  required final String projectPath,
}) {
  final root = p.normalize(projectPath);
  final target = p.normalize(absolutePath);
  final rel = p.relative(target, from: root);

  var ignored = false;
  for (final file in [
    File(p.join(root, '.gitignore')),
    File(p.join(root, '.git', 'info', 'exclude')),
  ]) {
    if (!file.existsSync()) continue;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final negated = line.startsWith('!');
      final pattern = negated ? line.substring(1) : line;
      if (matchesGitignorePattern(pattern, rel)) ignored = !negated;
    }
  }
  return ignored;
}

/// Matches one gitignore [pattern] against a project-relative path [rel].
@visibleForTesting
bool matchesGitignorePattern(final String pattern, final String rel) {
  var dirOnly = false;
  var anchored = false;
  var pat = pattern;

  if (pat.endsWith('/')) {
    dirOnly = true;
    pat = pat.substring(0, pat.length - 1);
  }
  if (pat.startsWith('/')) {
    anchored = true;
    pat = pat.substring(1);
  } else if (pat.contains('/')) {
    // A pattern containing an inner slash is root-anchored.
    anchored = true;
  }

  final regex = _globToRegExp(pat);
  final segments = rel.split('/');
  if (dirOnly) {
    // Matches any directory component in the path.
    for (var i = 0; i < segments.length - 1; i++) {
      final head = segments.take(i + 1).join('/');
      if (anchored ? regex.hasMatch(head) : regex.hasMatch(segments[i])) {
        return true;
      }
    }
    return false;
  }
  if (anchored) return regex.hasMatch(rel);
  // Unanchored: matches the basename at any depth.
  return segments.any(regex.hasMatch);
}

/// Compiles one gitignore pattern (without leading `/`, without trailing
/// `/`) to a full-match [RegExp]. Supports `*`, `?`, `**`, and character
/// classes pass through.
RegExp _globToRegExp(final String pattern) {
  final b = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        b.write('.*');
        i += 2;
        // Swallow a following slash: `a/**/b` also matches `a/b`.
        if (i < pattern.length && pattern[i] == '/') i++;
        continue;
      }
      b.write('[^/]*');
      i++;
      continue;
    }
    if (c == '?') {
      b.write('[^/]');
      i++;
      continue;
    }
    if (c == '[') {
      // Copy character class verbatim up to the closing bracket.
      final end = pattern.indexOf(']', i);
      if (end == -1) {
        b.write(RegExp.escape(c));
        i++;
        continue;
      }
      b.write(pattern.substring(i, end + 1));
      i = end + 1;
      continue;
    }
    b.write(RegExp.escape(c));
    i++;
  }
  b.write(r'$');
  return RegExp(b.toString());
}
