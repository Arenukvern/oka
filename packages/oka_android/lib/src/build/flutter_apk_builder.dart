import 'dart:io';

import 'package:oka_core/src/config/build_context.dart';
import '../pipeline/default_pipeline.dart';
import 'package:oka_core/src/pipeline/pipeline.dart';
import 'dependency_cache.dart';
import 'dependency_suggest.dart';
import 'flutter_assemble.dart';
import 'plugin_discovery.dart';
import 'sdk_locator.dart';

/// Error thrown when required Android SDK build-tools are missing.
class AndroidSdkMissingException implements Exception {
  final String message;
  AndroidSdkMissingException(this.message);

  @override
  String toString() => message;
}

/// Default no-Gradle Flutter APK builder.
///
/// Pipeline:
/// 1. Discover plugins + generate host sources
/// 2. flutter assemble (assets / kernel)
/// 3. Extract libflutter.so (+ libapp.so for release)
/// 4. Resolve AndroidX JARs
/// 5. aapt2 / javac / d8 / package / sign (requires Android SDK)
class FlutterApkBuilder {
  final SdkLocator sdkLocator;
  final bool verbose;
  final FlutterAssembler assembler;
  final PluginDiscovery pluginDiscovery;
  final DependencyCache? dependencyCache;
  final bool allowNetwork;

  /// When true, skip process tools and only stage layout (tests).
  final bool layoutOnly;

  /// When false (soft plugins), unsupported plugins are skipped with warnings.
  /// When true (default strict), unsupported plugins abort the build.
  final bool strictPlugins;

  FlutterApkBuilder(
    this.sdkLocator, {
    this.verbose = false,
    FlutterAssembler? assembler,
    PluginDiscovery? pluginDiscovery,
    this.dependencyCache,
    this.allowNetwork = true,
    this.layoutOnly = false,
    this.strictPlugins = true,
  }) : assembler = assembler ?? FlutterAssembler(verbose: verbose),
       pluginDiscovery = pluginDiscovery ?? PluginDiscovery(verbose: verbose);

  Future<BuildArtifact> buildApk(BuildContext ctx) async {
    final start = DateTime.now();
    final isAab = ctx.buildAab;
    try {
      print(
        '🚀 Building Flutter ${ctx.mode.name} ${isAab ? 'AAB' : 'APK'} '
        '(no-Gradle)...',
      );

      final overrides = await PipelineOverrides.load(ctx.projectPath);
      final Pipeline pipeline;
      if (isAab) {
        pipeline = await defaultAabPipeline(
          sdkLocator,
          verbose: verbose,
          strictPlugins: strictPlugins,
          allowNetwork: allowNetwork,
          dependencyCache: dependencyCache,
          overrides: overrides,
        );
      } else {
        pipeline = await defaultApkPipeline(
          sdkLocator,
          verbose: verbose,
          layoutOnly: layoutOnly,
          strictPlugins: strictPlugins,
          allowNetwork: allowNetwork,
          dependencyCache: dependencyCache,
          overrides: overrides,
        );
      }
      final result = await pipeline.run(ctx);
      if (!result.ok) {
        throw Exception(result.error);
      }
      final apkPath = result.data['apk_path'] as String?;
      final size = apkPath == null ? 0 : await File(apkPath).length();
      final duration = DateTime.now().difference(start);
      if (result.data['layout_only'] != true) {
        print(
          '✅ Flutter ${isAab ? 'AAB' : 'APK'} build successful in '
          '${duration.inSeconds}s',
        );
        print('📍 ${isAab ? 'AAB' : 'APK'}: $apkPath');
        print('📊 Size: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      }
      return BuildArtifact.fromJson({
        'apk_path': apkPath ?? '',
        'size': size,
        'build_duration': duration.inMilliseconds,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'success': true,
      });
    } on AndroidSdkMissingException catch (e) {
      final duration = DateTime.now().difference(start);
      print('❌ $e');
      print('   Run: oka doctor');
      print('   Install Android SDK build-tools and set ANDROID_SDK_ROOT.');
      return BuildArtifact.fromJson({
        'apk_path': '',
        'size': 0,
        'build_duration': duration.inMilliseconds,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'success': false,
        'error': e.toString(),
      });
    } catch (e, st) {
      final duration = DateTime.now().difference(start);
      print('❌ Flutter APK build failed: $e');
      await _printDependencyHint(e.toString());
      if (verbose) print(st);
      return BuildArtifact.fromJson({
        'apk_path': '',
        'size': 0,
        'build_duration': duration.inMilliseconds,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  /// When a failure mentions a missing class, suggest the Maven artifact
  /// (ADR-0002 dependency recovery).
  static Future<void> _printDependencyHint(String errorText) async {
    final missing = extractMissingClass(errorText);
    if (missing == null) return;
    try {
      final resolver = MissingDependencyResolver();
      final suggestions = await resolver.suggest(missing);
      print('');
      print(formatSuggestions(missing, suggestions));
    } catch (_) {
      // Suggestions are best-effort; never mask the original error.
    }
  }
}
