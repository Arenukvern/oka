import 'dart:io';

import 'package:path/path.dart' as p;

import '../../build/apk_layout.dart';
import '../../build/dependency_cache.dart';
import '../../build/host_codegen.dart';
import '../../build/launcher_icon.dart';
import '../../build/plugin_discovery.dart';
import '../../build/plugin_packager.dart';
import '../../build/sdk_locator.dart';
import 'asset_steps.dart' show DeeplinkConfig;
import '../../config/build_context.dart';
import '../pipeline.dart';

/// Ensures Android SDK packaging tools exist; fails loudly otherwise.
///
/// Preserves ADR-0001: never fall back to Gradle / `flutter build apk`.
class EnsureAndroidSdkStep implements BuildStep {
  final SdkLocator sdkLocator;
  @override
  String get name => 'ensure-android-sdk';

  EnsureAndroidSdkStep(this.sdkLocator);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    try {
      await sdkLocator.validatePackagingTools();
      return StepResult.success();
    } on Exception catch (e) {
      return StepResult.failure(
        'Android SDK / build-tools not available (required for no-Gradle APK '
        'packaging).\nDetails: $e\n'
        'Install Android command-line tools, then set ANDROID_SDK_ROOT or '
        'ANDROID_HOME.\nRun `oka doctor` for a full check. Oka does not use '
        'Gradle or `flutter build apk`.',
      );
    }
  }
}

/// Resolves target ABIs from config + CLI into [PipelineState.abis].
class ResolveAbisStep implements BuildStep {
  @override
  String get name => 'resolve-abis';

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    state.abis = resolveAbis(
      configAbis: ctx.config.android.abis,
      targetAbi: ctx.targetAbi,
    );
    if (ctx.verbose) print('   ABIs: ${state.abis.join(', ')}');
    await Directory(ctx.buildDir).create(recursive: true);
    return StepResult.success();
  }
}

/// Discovers plugins and packages them (sources, jars, natives).
class PluginPackagingStep implements BuildStep {
  final SdkLocator sdkLocator;
  final PluginDiscovery pluginDiscovery;
  final DependencyCache dependencyCache;
  final bool strictPlugins;

  @override
  String get name => 'plugin-packaging';

  PluginPackagingStep({
    required this.sdkLocator,
    required this.pluginDiscovery,
    required this.dependencyCache,
    this.strictPlugins = true,
  });

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('🔌 Discovering and packaging Flutter plugins...');
    final discovery = await pluginDiscovery.discover(ctx.projectPath);
    final support = decidePluginSupport(discovery, strict: strictPlugins);
    if (!support.allowBuild) {
      pluginDiscovery.ensureSupported(discovery, strict: true);
    }
    if (support.softMode && support.warnings.isNotEmpty) {
      print('⚠️  Soft plugin mode — skipping unsupported plugins:');
      for (final w in support.warnings) {
        print('   - $w');
      }
    }

    final packager = PluginPackager(
      dependencyCache: dependencyCache,
      sdkLocator: sdkLocator,
      verbose: ctx.verbose,
    );
    final packaged = await packager.packageAll(
      discovery,
      buildDir: ctx.buildDir,
      abis: state.abis,
      requireAll: strictPlugins,
    );
    if (packaged.failed.isNotEmpty && strictPlugins) {
      final msg = packaged.failed
          .map((f) => '${f.plugin.name}: ${f.failureReason}')
          .join('\n  - ');
      return StepResult.failure(
        'Failed to package required plugins for no-Gradle APK:\n  - $msg',
      );
    }
    if (packaged.failed.isNotEmpty && !strictPlugins) {
      for (final f in packaged.failed) {
        print(
          '⚠️  Skipping unpackageable plugin ${f.plugin.name}: '
          '${f.failureReason}',
        );
      }
    }

    final registrations = packaged.registrations;
    if (registrations.isEmpty &&
        discovery.androidPlugins.any((p) => p.pluginClass != null)) {
      return StepResult.failure(
        'GeneratedPluginRegistrant would be empty but Android plugins with '
        'pluginClass were discovered. Plugin packaging failed to produce '
        'registrations.',
      );
    }
    print(
      '   Plugins (Android): ${discovery.androidPlugins.length} '
      '(registrations: ${registrations.length}, '
      'failed: ${packaged.failed.length})',
    );

    state.pluginDiscovery = discovery;
    state.packagedPlugins = packaged;
    state.registrations = registrations;
    return StepResult.success();
  }
}

/// Generates MainActivity, GeneratedPluginRegistrant, manifest and minimal res.
class HostCodegenStep implements BuildStep {
  /// Deeplink declarations rendered as extra intent-filters on MainActivity.
  final List<DeeplinkConfig> deeplinks;

  /// Launcher icon configuration (adaptive, vector-first).
  final IconConfig iconConfig;

  @override
  String get name => 'host-codegen';

  HostCodegenStep({
    this.deeplinks = const [],
    this.iconConfig = const IconConfig(),
  });

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('📝 Generating Android host sources...');
    final hostDir = p.join(ctx.buildDir, 'host_java');
    final packageName = ctx.config.android.packageName;

    final mainRel = mainActivityRelativePath(packageName);
    final mainPath = p.join(hostDir, mainRel);
    await File(mainPath).parent.create(recursive: true);
    await File(mainPath).writeAsString(generateMainActivityJava(packageName));

    final registrantPath = p.join(
      hostDir,
      'io',
      'flutter',
      'plugins',
      'GeneratedPluginRegistrant.java',
    );
    await File(registrantPath).parent.create(recursive: true);
    await File(
      registrantPath,
    ).writeAsString(generatePluginRegistrantJava(state.registrations));

    // Minimal res for aapt2 — values + launcher icon resources.
    final resDir = p.join(ctx.buildDir, 'res');
    await Directory(p.join(resDir, 'values')).create(recursive: true);
    await File(p.join(resDir, 'values', 'strings.xml')).writeAsString('''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">${ctx.config.name.isEmpty ? 'App' : ctx.config.name}</string>
</resources>
''');

    // Launcher icon (adaptive, vector-first — see launcher_icon.dart).
    String iconRef = '';
    try {
      final icons = await stageLauncherIcons(
        resDir,
        iconConfig,
        projectPath: ctx.projectPath,
      );
      iconRef = icons.manifestRef;
      if (ctx.verbose) {
        print('   icon resources: ${icons.written.join(', ')}');
      }
    } on Exception catch (e) {
      return StepResult.failure('launcher icon: $e');
    }

    final manifest = generateAndroidManifestXml(
      packageName: packageName,
      label: ctx.config.name.isEmpty ? packageName : ctx.config.name,
      minSdk: ctx.config.android.minSdk.isEmpty
          ? '21'
          : ctx.config.android.minSdk,
      targetSdk: ctx.config.android.targetSdk.isEmpty
          ? '34'
          : ctx.config.android.targetSdk,
      debuggable: ctx.mode.isDebug,
      extraIntentFilters: deeplinks.map((d) => d.intentFilterXml).join('\n'),
      iconRef: iconRef,
    );
    await File(
      p.join(ctx.buildDir, 'AndroidManifest.xml'),
    ).writeAsString(manifest);

    state.hostDir = hostDir;
    return StepResult.success();
  }
}
