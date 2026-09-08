/// Pure shell validation (ADR-0016): issues are computed before any I/O.
///
/// `validateWebShell` returns an empty list when the composed shell is
/// valid; each issue is an actionable message. File-existence checks
/// (icons) are the only filesystem reads — performed in
/// [ValidateWebShellStep] before anything is written.
library;

import 'dart:io';

import 'package:meta/meta.dart';

import 'composition.dart';
import 'spec/head_entry.dart';

/// Valid base href: empty is allowed (emitter skips the tag only when the
/// spec default is changed), otherwise must start and end with `/`.
bool isValidBaseHref(final String baseHref) =>
    baseHref.startsWith('/') &&
    baseHref.endsWith('/') &&
    !baseHref.contains('//');

/// Pure composition issues (no filesystem): identity, base-href format,
/// duplicate entries, phase sanity.
List<String> shellIssues(final WebShell shell) {
  final issues = <String>[];

  if (shell.title.trim().isEmpty) {
    issues.add(
      'shell title is empty — set WebShellSpec.title (it labels the '
      'document title and the PWA manifest name)',
    );
  }

  if (!isValidBaseHref(shell.baseHref)) {
    issues.add(
      'invalid base href "${shell.baseHref}" — base href must start and '
      'end with "/" and contain no empty segments (e.g. "/", "/app/"). '
      'Set WebShellSpec.baseHref or a contribution baseHref override',
    );
  }

  // Duplicate head entries (per identity key per variant kind).
  final seen = <String, String>{};
  for (final entry in shell.head) {
    final kind = entry is WebMetaEntry
        ? 'meta'
        : entry is WebLinkEntry
            ? 'link'
            : 'script';
    final key = '$kind:${entry.identityKey}';
    final previous = seen[key];
    if (previous != null) {
      issues.add(
        'duplicate head entry $key (also contributed by $previous) — '
        'remove one of them; duplicate tags drift between stores',
      );
    } else {
      seen[key] = entry.phase.name;
    }
  }

  // Phase sanity inside the composed order: preconnects may not follow a
  // storeSdk entry (would defeat the preconnect for the SDK origin).
  final phases = shell.head.map((final e) => e.phase.order).toList();
  for (var i = 1; i < phases.length; i++) {
    if (phases[i - 1] > phases[i]) {
      issues.add(
        'composed head entries are not phase-ordered at position $i — '
        'this is a composition bug (WebShell.head must sort by phase: '
        'preconnect < storeSdk < app); please report it',
      );
      break;
    }
  }

  return issues;
}

/// Icon + artifact existence issues — the ONLY filesystem reads
/// validation performs (existence checks, no content, no image
/// processing).
@visibleForTesting
List<String> iconIssues(final WebShell shell, {required final String webDir}) {
  final issues = <String>[];
  final icons = shell.manifest.icons;
  for (final entry in icons.declared.entries) {
    final file = File('$webDir/${entry.key}');
    if (!file.existsSync()) {
      issues.add(
        'declared icon "${entry.key}" (${entry.value}) does not exist '
        'under $webDir — WebIconSpec declares existing PNG paths; '
        'generate the file or drop the declaration',
      );
    }
  }
  return issues;
}

/// Full validation: pure issues + icon existence. Empty list = valid.
List<String> validateWebShell(
  final WebShell shell, {
  required final String webDir,
}) => [...shellIssues(shell), ...iconIssues(shell, webDir: webDir)];
