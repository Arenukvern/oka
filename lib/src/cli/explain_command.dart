import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// `oka explain` — composes and validates the build plan with **zero tool
/// invocations** (ADR-0007). Reports the step list with artifact chains,
/// signing resolution, version injection, plugin plan and warnings.
///
/// `oka build --dry-run` routes here.
class ExplainCommand {
  Future<void> run(List<String> args) async {
    final release = args.contains('--release');
    final aab = args.contains('--aab') || args.contains('aab');
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
    if (config.toJson()['pipeline'] is Map &&
        (config.toJson()['pipeline'] as Map)['dart_entrypoint'] != null) {
      print(
        '  ⛓️  dart_entrypoint: '
        '${(config.toJson()['pipeline'] as Map)['dart_entrypoint']} '
        '— `oka build` delegates there (hook owns the pipeline)',
      );
    }
    for (final step in AndroidPipeline.defaultSteps) {
      final req = describeArtifacts(step.requires);
      final prov = describeArtifacts(step.provides);
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
}
