import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'oka_workspace_root.dart';

/// Workspace root anchor checked in at the repo root.
const _anchorRelative = okaWorkspaceRootAnchor;

/// Resolves the oka repository root (cwd-independent).
String findOkaRepoRoot([String? start]) =>
    findOkaWorkspaceRoot(start: start);

/// Repo-rooted file for source-contract tests (immune to [Directory.current] races).
File repoFile(List<String> relativeSegments) => File(
      p.joinAll([findOkaRepoRoot(), ...relativeSegments]),
    );

/// Fails loudly when [Directory.current] no longer looks like the oka workspace.
///
/// [Directory.current] is shared across every test isolate in the runner process;
/// suites that chdir into temp dirs must not mutate it (see init_command_test).
void guardOkaWorkspaceCwd() {
  final cwd = Directory.current.path;
  final pubspec = File(p.join(cwd, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    fail(
      'Directory.current ($cwd) is not the oka workspace root '
      '(pubspec.yaml missing). Another test suite likely mutated '
      'Directory.current; resolve repo paths via test/support/repo_root.dart '
      'instead of relative paths.',
    );
  }
  final text = pubspec.readAsStringSync();
  if (!RegExp(r'^name:\s*oka_workspace\s*$', multiLine: true).hasMatch(text)) {
    fail(
      'Directory.current ($cwd) is not the oka workspace root '
      '(expected name: oka_workspace). Another test suite likely mutated '
      'Directory.current while this suite was running.',
    );
  }
  if (!File(p.join(cwd, _anchorRelative)).existsSync()) {
    fail(
      'Directory.current ($cwd) lacks $_anchorRelative despite oka_workspace '
      'pubspec — treat this as a cwd leak or mis-rooted test run.',
    );
  }
}
