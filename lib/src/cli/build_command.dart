import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'explain_command.dart';

/// Recursively converts YamlMap/YamlList to Map/List
dynamic _yamlToJson(final Object? value) {
  if (value is YamlMap) {
    return value.map(
      (final k, final v) => MapEntry(k.toString(), _yamlToJson(v)),
    );
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Build command to compile APK or AAB
class BuildCommand {
  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('release', negatable: false, help: 'Build release variant')
      ..addFlag(
        'debug',
        negatable: false,
        help: 'Build debug variant (default)',
      )
      ..addFlag('profile', negatable: false, help: 'Build profile variant')
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Show the validated build plan without building (same as oka explain)',
      )
      ..addFlag(
        'flutter',
        negatable: false,
        help:
            'Deprecated alias: default path is already no-Gradle Flutter packaging',
      )
      ..addFlag(
        'native-android',
        negatable: false,
        help:
            'Use legacy pure-Android SDK pipeline (no Flutter assemble; not for Flutter apps)',
      )
      ..addFlag(
        'soft-plugins',
        negatable: false,
        hide: true,
        help:
            'Escape hatch only: skip plugins that fail packaging. '
            'Default builds package all plugins completely.',
      )
      ..addFlag(
        'aab',
        negatable: false,
        help: 'Build Android App Bundle (AAB) instead of APK',
      )
      ..addFlag(
        'verify-aab',
        negatable: false,
        help:
            'After building an AAB, verify it with bundletool build-apks '
            '(universal mode). Requires bundletool: oka get bundletool',
      )
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Verbose output')
      ..addOption('flavor', help: 'Build flavor')
      ..addOption(
        'abi',
        help: 'Single ABI to build (e.g. arm64-v8a)',
        defaultsTo: '',
      )
      ..addOption(
        'target',
        help: 'Flutter entrypoint (e.g. lib/main_prod.dart)',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Dart defines passed to flutter assemble (key=value)',
      )
      ..addOption(
        'dart-define-from-file',
        help: 'JSON file with Dart defines',
      );

    final results = parser.parse(args);
    if (results['dry-run'] as bool) {
      await ExplainCommand().run(args);
      return;
    }
    final verbose = results['verbose'] as bool;
    final useNativeAndroid = results['native-android'] as bool;
    final buildAab = results['aab'] as bool;
    // Default is complete plugin packaging (strict). --soft-plugins is a
    // hidden escape hatch, not the supported path for real apps.
    final softPlugins = results['soft-plugins'] as bool;
    final strictPlugins = !softPlugins;

    // Determine build mode
    final BuildMode mode;
    if (results['release'] as bool) {
      mode = BuildMode.release;
    } else if (results['profile'] as bool) {
      mode = BuildMode.profile;
    } else {
      mode = BuildMode.debug;
    }

    // Remaining args may include "apk" / "aab" subcommand tokens
    final rest = results.rest;
    final wantsAab = buildAab || rest.any((r) => r.toLowerCase() == 'aab');

    print('🔨 Building ${mode.name} ${wantsAab ? 'AAB' : 'APK'}...\n');

    // ADR-0006/0010: project-declared Dart entrypoint owns the pipeline.
    // `oka build` delegates (same args/env) — the hook composes the
    // declarative Oka root. Resolution order: oka.yaml
    // `pipeline.dart_entrypoint` → `tool/oka_pipeline.dart` →
    // `bin/oka_pipeline.dart` (convention, so full-Dart projects need no
    // oka.yaml at all). No-entrypoint projects keep the AOT fast path.
    final projectPath = Directory.current.path;
    final dartEntrypoint = await findPipelineEntrypoint(projectPath);
    if (dartEntrypoint != null) {
      print('🪝 Delegating to Dart entrypoint: $dartEntrypoint\n');
      final defines = [
        ...results['dart-define'] as List<String>,
      ];
      final defineFile = results['dart-define-from-file'] as String?;
      final args = [
        '--platform',
        'android',
        if (mode != BuildMode.debug) '--${mode.name}',
        if (wantsAab) '--aab',
        if (wantsAab && (results['verify-aab'] as bool)) '--verify-aab',
        if (verbose) '--verbose',
        if ((results['flavor'] as String?)?.isNotEmpty ?? false)
          ...['--flavor', results['flavor'] as String],
        if ((results['abi'] as String).isNotEmpty) ...[
          '--abi',
          results['abi'] as String,
        ],
        if ((results['target'] as String?)?.isNotEmpty ?? false)
          ...['--target', results['target'] as String],
        for (final d in defines) ...['--dart-define', d],
        if (defineFile != null) ...['--dart-define-from-file', defineFile],
      ];
      final proc = await Process.run(
        'dart',
        ['run', dartEntrypoint, ...args],
        workingDirectory: projectPath,
        environment: {
          if (verbose) 'OKA_VERBOSE': '1',
          'OKA_MODE': mode.name,
          if (wantsAab) 'OKA_AAB': '1',
        },
        runInShell: true,
      );
      stdout.write(proc.stdout);
      stderr.write(proc.stderr);
      exit(proc.exitCode);
    }

    // Load oka.yaml (still required for the AOT yaml-config fast path —
    // full-Dart projects never reach this line, ADR-0010).
    final okaYamlFile = File('oka.yaml');
    if (!await okaYamlFile.exists()) {
      print('❌ oka.yaml not found (and no Dart pipeline entrypoint at');
      print('   tool/oka_pipeline.dart or bin/oka_pipeline.dart)');
      print('   Run "oka init" first to create configuration');
      exit(1);
    }

    final okaYamlContent = await okaYamlFile.readAsString();
    final okaYamlData = loadYaml(okaYamlContent);
    final config = OkaConfig.fromJson(_yamlToJson(okaYamlData));

    if (verbose) {
      print('📋 Configuration:');
      print('   Package: ${config.android.packageName}');
      print('   Min SDK: ${config.android.minSdk}');
      print('   Target SDK: ${config.android.targetSdk}');
      print('   Compile SDK: ${config.android.compileSdk}');
      print('');
    }

    final buildDir = p.join(projectPath, '.oka_cache', 'build', mode.name);
    final cacheDir = p.join(projectPath, '.oka_cache');
    await Directory(buildDir).create(recursive: true);

    final targetAbi = (results['abi'] as String?) ?? '';

    final buildContext = BuildContext.fromJson({
      'project_path': projectPath,
      'build_dir': buildDir,
      'mode': mode.name,
      'config': config.toJson(),
      'cache_dir': cacheDir,
      'temp_dir': p.join(buildDir, 'temp'),
      'flutter_sdk_path': '',
      'android_sdk_path': '',
      'verbose': verbose,
      'flavor': results['flavor'] ?? '',
      'target_abi': targetAbi,
      'build_aab': wantsAab,
      'target_override': (results['target'] as String?) ?? '',
      'dart_defines': {
        for (final d in results['dart-define'] as List<String>)
          ..._parseSingleDefine(d),
        ..._parseDefineFile(results['dart-define-from-file'] as String?),
      },
    });

    final locator = SdkLocator(verbose: verbose);

    BuildArtifact artifact;
    if (useNativeAndroid) {
      // Legacy non-Flutter Android shell pipeline (not for Flutter apps).
      print('⚙️  Using legacy native-android pipeline (no Flutter assemble)\n');
      final builder = AndroidBuilder(locator, verbose: verbose);
      artifact = await builder.buildApk(buildContext);
    } else {
      // Default: no-Gradle Flutter APK (never flutter build apk / Gradle).
      if (softPlugins) {
        print('🧩 Soft plugin mode: unsupported plugins will be skipped\n');
      }
      final builder = FlutterApkBuilder(
        locator,
        verbose: verbose,
        strictPlugins: strictPlugins,
      );
      artifact = await builder.buildApk(buildContext);
    }

    if (!artifact.success) {
      print('\n❌ Build failed!');
      if (artifact.error.isNotEmpty) {
        print('   ${artifact.error}');
      }
      exit(1);
    }

    print('\n✅ Build successful!');
    print('📍 ${wantsAab ? 'AAB' : 'APK'}: ${artifact.apkPath}');
    print(
      '⏱️  Build time: ${(artifact.buildDuration / 1000).toStringAsFixed(1)}s',
    );
    print('📊 Size: ${(artifact.size / 1024 / 1024).toStringAsFixed(2)} MB');

    if (wantsAab && (results['verify-aab'] as bool)) {
      final ok = await _verifyAab(artifact.apkPath, verbose: verbose);
      if (!ok) exit(1);
    }
  }

  /// Parses a single `key=value` define; bare key → 'true'.
  static Map<String, String> _parseSingleDefine(String define) {
    final i = define.indexOf('=');
    if (i < 0) return {define: 'true'};
    return {define.substring(0, i): define.substring(i + 1)};
  }

  /// Expands --dart-define-from-file (JSON object).
  static Map<String, String> _parseDefineFile(String? path) {
    if (path == null || path.isEmpty) return const {};
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('❌ dart-define-from-file not found: $path');
      exit(1);
    }
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map) {
      stderr.writeln('❌ dart-define-from-file must be a JSON object: $path');
      exit(1);
    }
    return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// bundletool verification loop for AABs (ADR-0004).
  ///
  /// An .aab cannot be installed directly; build-apks exercises the same
  /// parsing/generation path as Play. Optionally install the universal APK.
  Future<bool> _verifyAab(String aabPath, {required bool verbose}) async {
    print('\n🔍 Verifying AAB with bundletool...');
    try {
      final ks = await debugKeystore();
      final apksPath = '${p.withoutExtension(aabPath)}.apks';
      final result = await verifyAabWithBundletool(
        aabPath: aabPath,
        outputApksPath: apksPath,
        keystorePath: ks,
        keyAlias: 'androiddebugkey',
        keyPass: 'android',
        verbose: verbose,
      );
      if (!result.ok) {
        print('❌ AAB verification failed:\n${result.error}');
        return false;
      }
      print('✅ bundletool accepted the bundle: $apksPath');

      final universalDir = p.join(p.dirname(aabPath), 'universal');
      final universalApk = await extractUniversalApk(
        apksPath,
        p.join(universalDir, 'app-universal.apk'),
      );
      print('📱 Universal APK extracted: $universalApk');
      print('   Install on a device with:');
      print('     adb install -r $universalApk');
      return true;
    } on Exception catch (e) {
      print('❌ AAB verification failed: $e');
      return false;
    }
  }
}
