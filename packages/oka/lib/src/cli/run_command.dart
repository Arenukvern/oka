import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

/// A target discovered from the project entrypoint (ADR-0015).
class DeclaredTarget {
  const DeclaredTarget({required this.name, required this.description});

  factory DeclaredTarget.fromJson(final Map<String, dynamic> json) =>
      DeclaredTarget(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
      );

  final String name;
  final String description;
}

/// `oka run <target>` — runs a project-declared target (ADR-0015).
///
/// Delegates to the project entrypoint (`tool/oka_pipeline.dart` /
/// `bin/oka_pipeline.dart` — the same discovery `oka build` uses) with
/// `--oka-run-target <name>`; the entrypoint's [okaRun] resolves the target
/// against its `Oka(targets: [...])` composition, validates the compiled
/// steps, and runs them. Any flags after the target name are forwarded.
class RunCommand {
  Future<void> run(final List<String> args) async {
    final projectPath = Directory.current.path;
    final entrypoint = await findPipelineEntrypoint(projectPath);

    if (args.isEmpty || args.first.startsWith('-')) {
      // Usage error — help the user by listing the discovered targets.
      if (entrypoint == null) {
        stderr.writeln(noEntrypointMessage('run'));
        exit(1);
      }
      final targets = await loadDeclaredTargets(
        projectPath: projectPath,
        entrypoint: entrypoint,
      );
      stderr.writeln(
        'Usage: oka run <target> [flags forwarded to the target]\n'
        '${targetsMessage(targets)}',
      );
      exit(1);
    }

    final targetName = args.first;
    final rest = args.skip(1).toList();

    if (entrypoint == null) {
      stderr.writeln(noEntrypointMessage('run $targetName'));
      exit(1);
    }

    await delegateToTarget(
      projectPath: projectPath,
      entrypoint: entrypoint,
      targetName: targetName,
      args: rest,
    );
  }
}

/// Unknown-verb dispatch (ADR-0015): core verbs resolve first in the CLI
/// switch; anything else loads the project entrypoint and either dispatches
/// to a matching target or fails naming the available targets. When no
/// entrypoint exists, says so and points at `oka init`.
Future<void> dispatchUnknownVerb(
  final String command,
  final List<String> args,
) async {
  final projectPath = Directory.current.path;
  final entrypoint = await findPipelineEntrypoint(projectPath);
  if (entrypoint == null) {
    stderr.writeln(noEntrypointMessage(command));
    exit(1);
  }
  final targets = await loadDeclaredTargets(
    projectPath: projectPath,
    entrypoint: entrypoint,
  );
  if (targets.any((final t) => t.name == command)) {
    await delegateToTarget(
      projectPath: projectPath,
      entrypoint: entrypoint,
      targetName: command,
      args: args,
    );
  }
  stderr.writeln(unknownVerbMessage(command, targets));
  exit(1);
}

/// Loads the targets declared by the project entrypoint (ADR-0015).
///
/// Runs `dart run <entrypoint> --oka-list-targets` — the entrypoint's
/// `okaRun` answers with a JSON array of `{name, description}`. Exits with
/// the entrypoint's diagnostics when it fails to load.
Future<List<DeclaredTarget>> loadDeclaredTargets({
  required final String projectPath,
  required final String entrypoint,
}) async {
  final proc = await Process.run(
    'dart',
    ['run', entrypoint, '--oka-list-targets'],
    workingDirectory: projectPath,
    runInShell: true,
  );
  if (proc.exitCode != 0) {
    stdout.write(proc.stdout);
    stderr.write(proc.stderr);
    exit(proc.exitCode);
  }
  final decoded = jsonDecode(proc.stdout as String);
  if (decoded is! List) {
    throw FormatException(
      'entrypoint $entrypoint did not report targets as a JSON array',
    );
  }
  return [
    for (final e in decoded)
      DeclaredTarget.fromJson((e as Map).cast<String, dynamic>()),
  ];
}

/// Spawns `dart run <entrypoint> --oka-run-target <name>` and exits with its
/// code (same delegation path as `oka build`, ADR-0006/0010).
Future<void> delegateToTarget({
  required final String projectPath,
  required final String entrypoint,
  required final String targetName,
  required final List<String> args,
}) async {
  final proc = await Process.run(
    'dart',
    ['run', entrypoint, '--oka-run-target', targetName, ...args],
    workingDirectory: projectPath,
    runInShell: true,
  );
  stdout.write(proc.stdout);
  stderr.write(proc.stderr);
  exit(proc.exitCode);
}

/// Formats the discovered-targets listing appended to dispatch errors
/// (ADR-0015). With no declared targets, points at the composition root.
String targetsMessage(final List<DeclaredTarget> targets) {
  if (targets.isEmpty) {
    return '   This project declares no targets. Add them to the Oka\n'
        '   composition root (tool/oka_pipeline.dart): Oka(targets: [...])\n'
        '   — see ADR-0015.';
  }
  final buf = StringBuffer('   Available targets (oka run <target>):');
  for (final t in targets) {
    buf.write('\n     - ${t.name}: ${t.description}');
  }
  return buf.toString();
}

/// Unknown-verb error naming the available targets (ADR-0015).
String unknownVerbMessage(
  final String command,
  final List<DeclaredTarget> targets,
) =>
    '❌ Unknown command: $command\n${targetsMessage(targets)}';

/// Error for a command that cannot be a target because the project has no
/// entrypoint — points at `oka init` (ADR-0015).
String noEntrypointMessage(final String command) =>
    '❌ Unknown command: $command\n'
    '   No project entrypoint found (expected tool/oka_pipeline.dart or\n'
    '   bin/oka_pipeline.dart). Project targets live there — run `oka init`\n'
    '   to bootstrap a project, or `oka --help` for the core verbs.';
