import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// One desktop platform pipeline (ADR-0055): an honest delegation to
/// `flutter build <desktop> --release` with the delivery variant already
/// applied to the context (entrypoint → `--target`, defines →
/// `--dart-define`).
///
/// Delegation is **named as delegation** in [description] — the same law
/// as `oka_web`'s `flutter build web` step (ADR-0016): the native desktop
/// toolchain is Flutter's, and oka does not claim it as its own pipeline
/// until it owns one.
///
/// Artifact conventions (typed ids on the concrete pipelines):
/// * macOS: the `.app` bundle directory — `MacosPipeline.appBundle`
/// * Linux: the release bundle directory — `LinuxPipeline.bundle`
/// * Windows: the Release runner directory — `WindowsPipeline.bundle`
///
/// Publish tails (snap, msix/Partner Center, notarized DMG, Steam depot
/// uploads) are **channels** composed onto deliveries — see ADR-0055;
/// none ship in this package yet (roadmap rows).
class FlutterDesktopPipeline implements PlatformPipeline {
  const FlutterDesktopPipeline({
    required this.platform,
    required this.buildSubcommand,
    required this.artifactId,
    required this.defaultOutputDir,
    this.configOverrides = const {},
  });

  /// Platform selector (`macos` | `linux` | `windows`).
  @override
  final String platform;

  /// The flutter build subcommand (`macos` | `linux` | `windows`).
  final String buildSubcommand;

  /// The artifact id this pipeline provides (e.g. `macos-app-bundle`).
  final String artifactId;

  /// Default output directory, relative to the project root — where
  /// `flutter build <subcommand>` leaves the runnable product.
  final String defaultOutputDir;

  @override
  final Map<String, dynamic> configOverrides;

  /// Explain-text: the delegation, named as delegation.
  String get description =>
      'delegates to flutter build $buildSubcommand (not an oka-owned '
      'pipeline) — composes the delivery entrypoint and dart-defines';

  /// The resolved argument vector (pure — tested directly). Mirrors the
  /// delivery context the dispatcher transformed: the variant entrypoint
  /// arrives via `ctx.targetOverride` (the `--target` resolution order),
  /// the variant/overlay defines via `ctx.dartDefines`, the flavor via
  /// `ctx.flavor` (forwarded, never silently dropped — a flavor the
  /// project does not define fails the flutter tool loudly).
  List<String> buildArgs(BuildContext ctx) => [
    'build',
    buildSubcommand,
    if (ctx.mode == BuildMode.release) '--release',
    if (ctx.targetOverride.isNotEmpty) '--target=${ctx.targetOverride}',
    if (ctx.flavor.isNotEmpty) '--flavor=${ctx.flavor}',
    for (final e in ctx.dartDefines.entries)
      '--dart-define=${e.key}=${e.value}',
  ];

  @override
  Future<StepResult> run(BuildContext ctx) async {
    final executable = ctx.flutterSdkPath.isEmpty
        ? 'flutter'
        : p.join(ctx.flutterSdkPath, 'bin', 'flutter');
    final result = await ctx.runner.run(
      executable,
      buildArgs(ctx),
      workingDirectory: ctx.projectPath,
    );
    if (!result.ok) {
      return StepResult.failure(
        'flutter build $buildSubcommand failed (exit ${result.exitCode}):\n'
        '${result.stderr}\n${result.stdout}',
      );
    }
    final output = p.join(ctx.projectPath, defaultOutputDir);
    // Honest delegation includes honest artifacts: a green flutter tool
    // that left no product at the convention means the convention (or
    // the invocation) drifted — fail here, not downstream at publish.
    if (!Directory(output).existsSync()) {
      return StepResult.failure(
        'flutter build $buildSubcommand succeeded (exit 0) but the '
        'expected artifact is missing: $output — the $platform output '
        'convention drifted; inspect the flutter build output above.',
      );
    }
    ctx.log(
      'delegated to flutter build $buildSubcommand — '
      'NOT an oka-owned pipeline; artifact: $output',
    );
    return StepResult.success({artifactId: output});
  }
}

/// The macOS desktop pipeline: `flutter build macos --release`, providing
/// the `.app` bundle directory (`build/macos/Build/Products/Release`).
class MacosPipeline extends FlutterDesktopPipeline {
  const MacosPipeline({super.configOverrides})
    : super(
        platform: 'macos',
        buildSubcommand: 'macos',
        artifactId: 'macos-app-bundle',
        defaultOutputDir: 'build/macos/Build/Products/Release',
      );

  /// The `.app` bundle directory artifact.
  static const appBundle = Artifact<String>('macos-app-bundle');
}

/// The Linux desktop pipeline: `flutter build linux --release`, providing
/// the release bundle directory (`build/linux/x64/release/bundle`).
class LinuxPipeline extends FlutterDesktopPipeline {
  const LinuxPipeline({super.configOverrides})
    : super(
        platform: 'linux',
        buildSubcommand: 'linux',
        artifactId: 'linux-bundle',
        defaultOutputDir: 'build/linux/x64/release/bundle',
      );

  /// The release bundle directory artifact.
  static const bundle = Artifact<String>('linux-bundle');
}

/// The Windows desktop pipeline: `flutter build windows --release`,
/// providing the Release runner directory
/// (`build/windows/x64/runner/Release`).
class WindowsPipeline extends FlutterDesktopPipeline {
  const WindowsPipeline({super.configOverrides})
    : super(
        platform: 'windows',
        buildSubcommand: 'windows',
        artifactId: 'windows-bundle',
        defaultOutputDir: 'build/windows/x64/runner/Release',
      );

  /// The Release runner directory artifact.
  static const bundle = Artifact<String>('windows-bundle');
}
