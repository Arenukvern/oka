import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';

/// `oka explain` — composes and validates the build plan with **zero tool
/// invocations** (ADR-0007). Reports the step list with artifact chains,
/// signing resolution, version injection, plugin plan and warnings.
///
/// `oka build --dry-run` routes here.
class ExplainCommand {
  Future<void> run(List<String> args) async {
    // ADR-0015 (C2): `oka explain --targets` — list the project-declared
    // targets with their compiled step chains (no tool execution, no device
    // probing) instead of the platform build plan.
    if (args.contains('--targets')) {
      await _explainTargets();
      return;
    }

    final release = args.contains('--release');
    final aab = args.contains('--aab') || args.contains('aab');
    // ADR-0008: opt-in dependency-plan resolution. Cache-only by default;
    // --network fetches missing artifacts (hard failures then exit 1).
    final deps = args.contains('--deps');
    final network = args.contains('--network') || args.contains('--online');
    final defines = <String, String>{};
    String? target;
    var abi = '';
    for (final a in args) {
      if (a.startsWith('--dart-define=')) {
        final v = a.substring('--dart-define='.length);
        final i = v.indexOf('=');
        defines[v.substring(0, i < 0 ? v.length : i)] =
            i < 0 ? 'true' : v.substring(i + 1);
      }
      if (a.startsWith('--target=')) target = a.substring('--target='.length);
      if (a.startsWith('--abi=')) abi = a.substring('--abi='.length);
    }

    final projectPath = Directory.current.path;
    final mode = release ? BuildMode.release : BuildMode.debug;

    print('🔍 oka explain — build plan (no tools invoked)\n');

    // Config + overrides.
    final config = await loadOkaYaml(projectPath);
    final overrides = await PipelineOverrides.load(projectPath);
    final signing = await SigningConfig.autoResolve(
      config.android.packageName.isEmpty
          ? BuildContext.empty
          : BuildContext(
              projectPath: projectPath,
              buildDir: '',
              mode: mode,
              config: config,
            ),
    );

    print('── Project ─────────────────────────────────────');
    print('  name:        ${config.name}');
    print(
      '  version:     ${config.android.versionCode}/${config.android.versionName}'
      '${config.android.versionCode == 0 ? ' (from pubspec at build time)' : ''}',
    );
    print('  package:     ${config.android.packageName}');
    print(
      '  sdk:         min ${config.android.minSdk.isEmpty ? '(default)' : config.android.minSdk} '
      '/ target ${config.android.targetSdk.isEmpty ? '(default)' : config.android.targetSdk} '
      '/ compile ${config.android.compileSdk.isEmpty ? '(default)' : config.android.compileSdk}',
    );
    print('  mode:        ${mode.name}${aab ? ' (AAB)' : ' (APK)'}');
    if (defines.isNotEmpty) {
      print(
        '  dart-defines:${defines.entries.map((e) => ' ${e.key}=${e.value}').join(', ')}',
      );
    }
    if (target != null) print('  target:      $target');
    if (abi.isNotEmpty) print('  abi:         $abi');

    print('\n── Version injection ───────────────────────────');
    final version = resolveAndroidVersion(
      projectPath,
      configVersionCode: config.android.versionCode,
      configVersionName: config.android.versionName,
    );
    final versionOk =
        version.versionCode != 0 && version.versionName.isNotEmpty;
    print(
      '  ${versionOk ? '✅' : '❌'} versionCode=${version.versionCode} '
      'versionName=${version.versionName}',
    );
    if (!versionOk) {
      print('     → set pubspec `version: x.y.z+nn` or oka.yaml version_code');
    }

    print('\n── Signing ─────────────────────────────────────');
    if (signing != null && signing.isConfigured) {
      print('  ✅ keystore: ${signing.keystorePath} (alias ${signing.keyAlias})');
    } else if (mode.isRelease) {
      print('  ❌ no release keystore resolved — would be DEBUG-signed');
      print('     → android/key.properties or oka.yaml android.signing');
    } else {
      print('  ℹ️  debug keystore (debug build — ok)');
    }

    print('\n── Plugins ─────────────────────────────────────');
    final discovery = PluginDiscovery();
    final result = await discovery.discover(projectPath);
    final devDeps = devDependencyNames(projectPath);
    final excluded = {...overrides.excludePlugins};
    final autoExcluded = <String>[];
    for (final plugin in result.androidPlugins) {
      if (mode.isRelease && devDeps.contains(plugin.name)) {
        autoExcluded.add(plugin.name);
      }
      excluded.add(plugin.name);
    }
    print('  android plugins: ${result.androidPlugins.length}');
    for (final plugin in result.androidPlugins) {
      final note = autoExcluded.contains(plugin.name)
          ? '  (auto-excluded: dev-only, release)'
          : overrides.excludePlugins.contains(plugin.name)
          ? '  (excluded)'
          : '';
      print('    · ${plugin.name}$note');
    }
    if (autoExcluded.isNotEmpty) {
      print(
        '  ℹ️  dev-only plugins auto-excluded from release (ADR-0007): '
        '${autoExcluded.join(', ')}',
      );
    }

    if (deps) {
      print(
        '\n── Dependency plan (ADR-0008, ${network ? 'network' : 'cache-only'}) '
        '────────',
      );
      final cache = DependencyCache(allowNetwork: network);
      final packager = PluginPackager(
        dependencyCache: cache,
        sdkLocator: SdkLocator(),
      );
      final report = await buildDependencyPlan(
        plugins: result.androidPlugins,
        extraDeps: overrides.extraDeps,
        packager: packager,
        cache: cache,
        allowNetwork: network,
      );
      print(report.summary());
      if (report.hasFatal) {
        print(
          '\n❌ dependency plan has fatal findings — the build would fail '
          'at resolution time.',
        );
        exit(1);
      }
    }

    print('\n── Java level ──────────────────────────────────');
    final gradleFiles = result.androidPlugins
        .map((p) => p.path)
        .expand(
          (path) => ['$path/android/build.gradle', '$path/android/build.gradle.kts'],
        )
        .toList();
    final detected = detectRequiredJavaLevel(gradleFiles);
    final configJava = config.android.javaVersion;
    print(
      '  config: $configJava, plugins require: ${detected ?? 'nothing extra'}',
    );
    if (detected != null && detected > configJava) {
      print(
        '  ⚠️  java_version will be bumped $configJava → $detected at build time',
      );
    }

    print('\n── Pipeline ────────────────────────────────────');
    print('  mode: ${aab ? 'AAB' : 'APK'} default no-Gradle pipeline');
    // Hook notice: explicit oka.yaml key or convention discovery (ADR-0010).
    final entrypoint = await findPipelineEntrypoint(projectPath);
    if (entrypoint != null) {
      print(
        '  ⛓️  dart pipeline: $entrypoint — `oka build` delegates there '
        '(hook owns the pipeline)',
      );
    }
    for (final step in AndroidPipeline.defaultSteps) {
      final req = step.requires.map((a) => a.id).join(', ');
      final prov = step.provides.map((a) => a.id).join(', ');
      print(
        '    ${step.name.padRight(24)}'
        '${req.isEmpty ? '' : '← [$req] '}'
        '${prov.isEmpty ? '' : '→ [$prov]'}',
      );
    }
    if (overrides.maxSizeMb != null) {
      print('  size budget: ${overrides.maxSizeMb} MB (post-build lint)');
    }

    print('\n── Validation ──────────────────────────────────');
    final pipeline = Pipeline(AndroidPipeline.defaultSteps);
    final validationError = pipeline.validate();
    if (validationError == null) {
      print('  ✅ artifact chain valid');
    } else {
      print('  ❌ $validationError');
    }
    print(
      '\nDry-run complete — no tools invoked. Run `oka build${aab ? ' aab' : ' apk'}'
      '${release ? ' --release' : ''}` to build.',
    );
  }

  /// `oka explain --targets` (ADR-0015): lists each project-declared target's
  /// step chain — the same validated-plan surface as builds, with **zero
  /// tool invocations**. Loads the project entrypoint (same discovery as
  /// build/run) and asks it (machine mode: `--oka-describe-targets`) for the
  /// compiled chains; nothing is compiled or executed in this process.
  Future<void> _explainTargets() async {
    final projectPath = Directory.current.path;
    final entrypoint = await findPipelineEntrypoint(projectPath);
    if (entrypoint == null) {
      stderr.writeln(
        '❌ oka explain --targets: no project entrypoint found (expected\n'
        '   tool/oka_pipeline.dart or bin/oka_pipeline.dart). Project targets\n'
        '   live there — run `oka init` to bootstrap a project, or `oka --help`\n'
        '   for the core verbs.',
      );
      exit(1);
    }

    final targets = await loadDescribedTargets(
      projectPath: projectPath,
      entrypoint: entrypoint,
    );

    print('🔍 oka explain — project targets (no tools invoked)\n');
    print('  entrypoint: $entrypoint');
    if (targets.isEmpty) {
      print('\n  This project declares no targets. Add them to the Oka');
      print('  composition root ($entrypoint): Oka(targets: [...]) — see ADR-0015.');
      return;
    }

    for (final target in targets) {
      print('\n  ${target.name} — ${target.description}');
      if (target.error != null) {
        print('    ❌ target failed to compile: ${target.error}');
        continue;
      }
      for (final step in target.steps) {
        final req = step.requires.join(', ');
        final prov = step.provides.join(', ');
        print(
          '    ${step.name.padRight(24)}'
          '${req.isEmpty ? '' : '← [$req] '}'
          '${prov.isEmpty ? '' : '→ [$prov]'}',
        );
      }
      // ADR-0016 W1: pure, platform-agnostic detail lines the target
      // itself provides (composition render, deploy posture, …). The CLI
      // prints them without knowing what they describe.
      if (target.details.isNotEmpty) {
        print('    details:');
        for (final line in target.details) {
          print('      $line');
        }
      }
      print(
        '    ${target.isValid ? '✅ artifact chain valid' : '❌ ${target.validationError}'}',
      );
    }
    print('\nNo tools invoked. Run a target with `oka run <target>`.');
  }
}

/// A step of a target's described chain (ADR-0015).
class DescribedTargetStep {
  const DescribedTargetStep({
    required this.name,
    required this.requires,
    required this.provides,
  });

  factory DescribedTargetStep.fromJson(final Map<String, dynamic> json) =>
      DescribedTargetStep(
        name: json['name']?.toString() ?? '',
        requires: [
          for (final r in (json['requires'] as List? ?? const [])) r.toString(),
        ],
        provides: [
          for (final p in (json['provides'] as List? ?? const [])) p.toString(),
        ],
      );

  final String name;
  final List<String> requires;
  final List<String> provides;
}

/// A target discovered from the project entrypoint with its described step
/// chain (ADR-0015). [error] is set when the entrypoint failed to compile
/// the target at all; otherwise [validationError] carries the composition-
/// time artifact-chain failure (null = valid).
class DescribedTarget {
  const DescribedTarget({
    required this.name,
    required this.description,
    this.steps = const [],
    this.details = const [],
    this.validationError,
    this.error,
  });

  factory DescribedTarget.fromJson(final Map<String, dynamic> json) =>
      DescribedTarget(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        steps: [
          for (final s in (json['steps'] as List? ?? const []))
            DescribedTargetStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
        validationError: json['validationError']?.toString(),
        error: json['error']?.toString(),
        details: [
          for (final d in (json['details'] as List? ?? const [])) d.toString(),
        ],
      );

  final String name;
  final String description;
  final List<DescribedTargetStep> steps;
  final String? validationError;
  final String? error;

  /// Pure detail lines ([Target.explainDetails], ADR-0016 W1) — printed
  /// verbatim; the CLI never interprets them.
  final List<String> details;

  bool get isValid => validationError == null;
}

/// Loads the described target chains from the project entrypoint (ADR-0015).
///
/// Runs `dart run <entrypoint> --oka-describe-targets` — the entrypoint's
/// `okaRun` compiles each declared target **purely** (no tool execution) and
/// answers with a JSON array of chains. Exits with the entrypoint's
/// diagnostics when it fails to load.
Future<List<DescribedTarget>> loadDescribedTargets({
  required final String projectPath,
  required final String entrypoint,
}) async {
  final proc = await Process.run(
    'dart',
    ['run', entrypoint, '--oka-describe-targets'],
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
      'entrypoint $entrypoint did not report target chains as a JSON array',
    );
  }
  return [
    for (final e in decoded)
      DescribedTarget.fromJson((e as Map).cast<String, dynamic>()),
  ];
}
