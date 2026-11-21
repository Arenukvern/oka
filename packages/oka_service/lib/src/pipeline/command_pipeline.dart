import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// One command in a [CommandPipeline]: an argv sequence (oka never spawns
/// a shell) with an optional project-relative working directory.
@immutable
class CommandSpec {
  const CommandSpec(
    this.executable,
    this.arguments, {
    this.workingDirectory = '',
  });

  /// Executable name or path (`jaspr`, `dart`, `docker`, `tool/build.sh`).
  final String executable;

  /// Argument vector — separate elements, no shell quoting anywhere.
  final List<String> arguments;

  /// Project-relative working directory (empty = the project root).
  final String workingDirectory;

  /// The resolved working directory (absolute; empty spec dir → the
  /// project root).
  String resolveWorkingDirectory(BuildContext ctx) => workingDirectory.isEmpty
      ? ctx.projectPath
      : p.join(ctx.projectPath, workingDirectory);

  /// Debug string: executable plus the argument count.
  @override
  String toString() => '$executable (${arguments.length} args)';

  /// Field-wise equality.
  @override
  bool operator ==(Object other) =>
      other is CommandSpec &&
      other.executable == executable &&
      _listsEqual(other.arguments, arguments) &&
      other.workingDirectory == workingDirectory;

  @override
  int get hashCode =>
      Object.hash(executable, Object.hashAll(arguments), workingDirectory);

  static bool _listsEqual(List<String> a, List<String> b) =>
      a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);
}

/// The generic pipeline for non-GUI buildables (ADR-0055): a serverpod
/// server (`docker build`), a dart_frog bot, a Jaspr landing
/// (`jaspr build`), a Dart CLI (`dart compile exe`) — any argv sequence.
///
/// The [platform] selector is an open string (`'landing'`, `'server'`,
/// `'cli'`, …) — services have no GUI-platform semantics, and bare
/// `oka build --platform <selector>` selects them exactly like a GUI
/// pipeline. Delivery variants (store key is usually null here; defines
/// and overlays are not) apply to the context before this runs, so
/// command vectors read the delivery's [BuildContext] the same way GUI
/// pipelines do.
///
/// ```dart
/// const landing = CommandPipeline(
///   platform: 'landing',
///   description: 'jaspr build for the static landing site',
///   commands: [
///     CommandSpec('jaspr', ['build', '--no-track-flavor']),
///   ],
///   artifactId: 'landing-dir',
///   artifactPath: 'build/jaspr/web',
/// );
/// ```
///
/// Commands stop at the first failure with the captured output. When
/// [artifactId] and [artifactPath] are set, the resolved absolute path is
/// provided as the delivery artifact (directory or file — the consuming
/// channel declares which).
class CommandPipeline implements PlatformPipeline {
  const CommandPipeline({
    required this.platform,
    required this.commands,
    this.artifactId,
    this.artifactPath,
    this.configOverrides = const {},
    this.description,
  });

  /// Open platform selector (`landing`, `server`, `cli`, `service`, …).
  @override
  final String platform;

  /// The ordered argv sequence. Empty is legal (a declarative no-op
  /// pipeline — validation tools can still compose its context).
  final List<CommandSpec> commands;

  /// Artifact id provided on success (null = provides nothing).
  final String? artifactId;

  /// Artifact path, project-relative (used with [artifactId]).
  final String? artifactPath;

  @override
  final Map<String, dynamic> configOverrides;

  /// One-line description override (derived from the commands when
  /// omitted).
  final String? description;

  /// Explain text: the command list, honestly.
  String get explainDescription =>
      description ??
      'run ${commands.length} command(s): '
          '${commands.map((c) => c.executable).join(' → ')}';

  @override
  Future<StepResult> run(BuildContext ctx) async {
    for (final command in commands) {
      ctx.log('▶ ${command.executable} ${command.arguments.join(' ')}');
      final result = await ctx.runner.run(
        command.executable,
        command.arguments,
        workingDirectory: command.resolveWorkingDirectory(ctx),
      );
      if (!result.ok) {
        return StepResult.failure(
          'command "${command.executable}" failed '
          '(exit ${result.exitCode}):\n${result.stderr}\n${result.stdout}',
        );
      }
    }
    final id = artifactId;
    if (id == null || id.isEmpty) return StepResult.success();
    final artifact = p.join(ctx.projectPath, artifactPath ?? '');
    return StepResult.success({id: artifact});
  }
}
