/// Non-GUI buildables for oka (ADR-0055): the generic [CommandPipeline]
/// driving `jaspr build` / `dart compile exe` / `docker build` / any argv
/// sequence, plus the [GitHubReleasePublishTarget] channel.
///
/// Services, landing pages, bots, and CLIs are first-class delivery
/// citizens: a [CommandPipeline] provides the artifact, a channel
/// publishes it, and a delivery composes both by const reference — the
/// same matrix law as GUI builds, minus the GUI.
///
/// ```dart
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         targets: [
///           Delivery(
///             name: 'landing-gh-pages',
///             pipeline: CommandPipeline(
///               platform: 'landing',
///               commands: [CommandSpec('jaspr', ['build'])],
///               artifactId: 'landing-dir',
///               artifactPath: 'build/jaspr/web',
///             ),
///             channel: GhPagesDeployTarget(),
///           ),
///         ],
///       ),
///     );
/// ```
library;

export 'src/pipeline/command_pipeline.dart';
export 'src/publish/github_release_target.dart';
