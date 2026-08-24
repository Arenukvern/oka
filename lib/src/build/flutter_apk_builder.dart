import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/build_context.dart';
import 'aapt2_commands.dart';
import 'apk_layout.dart';
import 'dependency_cache.dart';
import 'engine_artifacts.dart';
import 'flutter_assemble.dart';
import 'host_codegen.dart';
import 'plugin_discovery.dart';
import 'plugin_packager.dart';
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
    try {
      print('🚀 Building Flutter ${ctx.mode.name} APK (no-Gradle)...');

      // Never use flutter build apk / Gradle.
      await _ensureAndroidSdkOrThrow(ctx);

      final abis = resolveAbis(
        configAbis: ctx.config.android.abis,
        targetAbi: ctx.targetAbi,
      );
      if (verbose) {
        print('   ABIs: ${abis.join(', ')}');
      }

      await Directory(ctx.buildDir).create(recursive: true);

      // 1. Plugins — full packaging (sources + deps + natives)
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

      final cache =
          dependencyCache ??
          DependencyCache(verbose: verbose, allowNetwork: allowNetwork);
      final packager = PluginPackager(
        dependencyCache: cache,
        sdkLocator: sdkLocator,
        verbose: verbose,
        allowNetwork: allowNetwork,
      );
      final packaged = await packager.packageAll(
        discovery,
        buildDir: ctx.buildDir,
        abis: abis,
        requireAll: strictPlugins,
      );
      if (packaged.failed.isNotEmpty && strictPlugins) {
        final msg = packaged.failed
            .map((f) => '${f.plugin.name}: ${f.failureReason}')
            .join('\n  - ');
        throw Exception(
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

      // Default complete path: real registrant from packable plugins.
      // Soft mode may omit only failed/unsupported plugins — never wipe all.
      final registrations = packaged.registrations;
      if (registrations.isEmpty &&
          discovery.androidPlugins.any((p) => p.pluginClass != null)) {
        throw Exception(
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

      // 2. Host sources
      print('📝 Generating Android host sources...');
      final hostDir = p.join(ctx.buildDir, 'host_java');
      await _writeHostSources(ctx, hostDir, registrations);

      // 3. Assemble Flutter assets
      print('🎨 Running flutter assemble...');
      final assembleOut = p.join(ctx.buildDir, 'assemble');
      final entrypoint = ctx.config.flutter.entrypoint.isEmpty
          ? 'lib/main.dart'
          : ctx.config.flutter.entrypoint;
      final assembleResult = await assembler.assembleApplication(
        projectPath: ctx.projectPath,
        outputDir: assembleOut,
        entrypoint: entrypoint,
        mode: ctx.mode,
        primaryAbi: abis.first,
        extraArgs: ctx.config.flutter.buildArgs,
      );
      if (!assembleResult.success) {
        throw Exception(
          'flutter assemble failed (exit ${assembleResult.exitCode}):\n'
          '${assembleResult.stderr}\n${assembleResult.stdout}',
        );
      }
      final assetsDir =
          assembleResult.flutterAssetsDir ??
          await findFlutterAssetsDir(assembleOut);
      if (assetsDir == null) {
        throw Exception(
          'flutter_assets not found under assemble output: $assembleOut',
        );
      }

      // 4. Engine natives
      print('📦 Extracting Flutter engine natives...');
      final flutterSdk = await sdkLocator.findFlutterSdk();
      final engine = EngineArtifacts(flutterSdk, verbose: verbose);
      final libDir = p.join(ctx.buildDir, 'lib');
      final libflutterByAbi = await engine.extractLibflutterForAbis(
        abis: abis,
        libDir: libDir,
        release: ctx.mode.isRelease || ctx.mode.isProfile,
      );

      // 5. Release AOT
      final libappByAbi = <String, String>{};
      if (ctx.mode.isRelease) {
        print('⚡ Assembling release AOT (libapp.so)...');
        for (final abi in abis) {
          final aotOut = p.join(ctx.buildDir, 'aot', normalizeAbi(abi));
          final aotResult = await assembler.assembleAot(
            projectPath: ctx.projectPath,
            outputDir: aotOut,
            entrypoint: entrypoint,
            abi: abi,
            extraArgs: ctx.config.flutter.buildArgs,
          );
          if (!aotResult.success) {
            throw Exception(
              'flutter AOT assemble failed for $abi: ${aotResult.stderr}',
            );
          }
          final so = await findLibappSo(aotOut);
          if (so == null) {
            throw Exception(
              'libapp.so/app.so not found for ABI $abi in $aotOut',
            );
          }
          final dest = p.join(libDir, normalizeAbi(abi), 'libapp.so');
          await File(dest).parent.create(recursive: true);
          await File(so).copy(dest);
          libappByAbi[normalizeAbi(abi)] = dest;
        }
      }

      // 6. AndroidX deps (best-effort; needed for javac)
      print('📚 Resolving AndroidX dependencies...');
      List<ResolvedJar> androidxJars = [];
      try {
        androidxJars = await cache.resolveFlutterAndroidX();
      } catch (e) {
        print('⚠️  AndroidX resolve incomplete: $e');
        print(
          '   Compile may fail without cached JARs under ~/.oka/cache/maven',
        );
      }

      // Merge plugin natives into lib/
      for (final entry in packaged.nativeLibsByAbi.entries) {
        final abi = normalizeAbi(entry.key);
        for (final so in entry.value) {
          final dest = p.join(libDir, abi, p.basename(so));
          await File(dest).parent.create(recursive: true);
          await File(so).copy(dest);
          if (verbose) print('   packaged native: $dest');
        }
      }

      // 7. Flutter embedding jar (from SDK) — classes only for javac/d8
      final embeddingJarFull = await engine.findFlutterJar(
        abis.first,
        release: ctx.mode.isRelease,
      );
      if (embeddingJarFull == null) {
        throw Exception(
          'flutter.jar (embedding) not found; run flutter precache',
        );
      }
      final embeddingJar = await engine.extractEmbeddingClassesJar(
        flutterJar: embeddingJarFull,
        destJarPath: p.join(ctx.buildDir, 'flutter_embedding_classes.jar'),
      );

      // 8. Android SDK tool pipeline
      if (layoutOnly) {
        // Test path: stage without aapt2/d8
        final staging = p.join(ctx.buildDir, 'staging');
        // Fake dex for layout tests
        final fakeDex = p.join(ctx.buildDir, 'classes.dex');
        await File(fakeDex).writeAsBytes([0x64, 0x65, 0x78, 0x0a]); // "dex\n"
        await stageApkLayout(
          stagingDir: staging,
          dexFile: fakeDex,
          flutterAssetsDir: assetsDir,
          libflutterByAbi: libflutterByAbi,
          libappByAbi: libappByAbi,
        );
        final apkPath = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');
        await zipStagingToApk(staging, apkPath);
        final entries = await listApkEntries(apkPath);
        final validation = validatePathSet(
          entries,
          spec: ApkLayoutSpec(abis: abis, requireLibapp: ctx.mode.isRelease),
        );
        if (!validation.ok) {
          throw Exception(
            'APK layout incomplete after packaging. Missing: ${validation.missing.join(', ')}',
          );
        }
        final size = await File(apkPath).length();
        final duration = DateTime.now().difference(start);
        return BuildArtifact.fromJson({
          'apk_path': apkPath,
          'size': size,
          'build_duration': duration.inMilliseconds,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'success': true,
        });
      }

      print('🔨 Compiling resources and Java/Kotlin (Android SDK tools)...');
      final dexFiles = await _compileAndDex(
        ctx: ctx,
        hostDir: hostDir,
        embeddingJar: embeddingJar,
        androidxJars: androidxJars.map((j) => j.jarPath).toList(),
        pluginJavaSources: packaged.allJavaSources,
        pluginKotlinSources: packaged.allKotlinSources,
        pluginJarDeps: packaged.allJarDeps,
        pluginResDirs: packaged.resDirs,
      );

      print('📱 Packaging APK...');
      final apkPath = await _packageAndSign(
        ctx: ctx,
        dexFiles: dexFiles,
        flutterAssetsDir: assetsDir,
        libflutterByAbi: libflutterByAbi,
        libappByAbi: libappByAbi,
        extraNativeByAbi: packaged.nativeLibsByAbi,
      );

      final size = await File(apkPath).length();
      final duration = DateTime.now().difference(start);
      print('✅ Flutter APK build successful in ${duration.inSeconds}s');
      print('📍 APK: $apkPath');
      print('📊 Size: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');

      // Validate layout — incomplete APK is a failed build (criterion 3).
      final entries = await listApkEntries(apkPath);
      final validation = validatePathSet(
        entries,
        spec: ApkLayoutSpec(abis: abis, requireLibapp: ctx.mode.isRelease),
      );
      if (!validation.ok) {
        throw Exception(
          'APK layout incomplete after packaging. Missing: ${validation.missing.join(', ')}. '
          'Present: ${validation.present.join(', ')}',
        );
      }

      return BuildArtifact.fromJson({
        'apk_path': apkPath,
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

  Future<void> _ensureAndroidSdkOrThrow(BuildContext ctx) async {
    if (layoutOnly) return;
    try {
      // Packaging only — adb/platform-tools are optional and must not abort.
      await sdkLocator.validatePackagingTools();
    } catch (e) {
      throw AndroidSdkMissingException(
        'Android SDK / build-tools not available (required for no-Gradle APK packaging).\n'
        'Details: $e\n'
        'Install Android command-line tools, then set ANDROID_SDK_ROOT or ANDROID_HOME.\n'
        'Run `oka doctor` for a full check. Oka does not use Gradle or `flutter build apk`.',
      );
    }
  }

  Future<void> _writeHostSources(
    BuildContext ctx,
    String hostDir,
    List<PluginRegistration> registrations,
  ) async {
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
    ).writeAsString(generatePluginRegistrantJava(registrations));

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
    );
    await File(
      p.join(ctx.buildDir, 'AndroidManifest.xml'),
    ).writeAsString(manifest);

    // Minimal res for aapt2 — simple values only (no adaptive icons).
    final resDir = p.join(ctx.buildDir, 'res');
    await Directory(p.join(resDir, 'values')).create(recursive: true);
    await File(p.join(resDir, 'values', 'strings.xml')).writeAsString('''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">${ctx.config.name.isEmpty ? 'App' : ctx.config.name}</string>
</resources>
''');
  }

  /// Prefer configured compile SDK platform; fall back to highest installed.
  Future<String> _resolveAndroidJar(
    String androidSdk,
    String compileSdk,
  ) async {
    final preferred = p.join(
      androidSdk,
      'platforms',
      'android-$compileSdk',
      'android.jar',
    );
    if (await File(preferred).exists()) return preferred;

    final platformsDir = Directory(p.join(androidSdk, 'platforms'));
    if (!await platformsDir.exists()) {
      throw Exception(
        'android.jar not found at $preferred and no platforms/ under $androidSdk. '
        'Run: oka get android-sdk',
      );
    }
    final jars = <String>[];
    await for (final e in platformsDir.list()) {
      if (e is Directory) {
        final jar = p.join(e.path, 'android.jar');
        if (await File(jar).exists()) jars.add(jar);
      }
    }
    if (jars.isEmpty) {
      throw Exception(
        'android.jar not found for compileSdk $compileSdk at $preferred',
      );
    }
    jars.sort();
    final fallback = jars.last;
    print(
      '⚠️  Platform android-$compileSdk missing; using ${p.basename(p.dirname(fallback))}',
    );
    return fallback;
  }

  /// Returns all multi-dex outputs (`classes.dex`, `classes2.dex`, …).
  Future<List<String>> _compileAndDex({
    required BuildContext ctx,
    required String hostDir,
    required String embeddingJar,
    required List<String> androidxJars,
    List<String> pluginJavaSources = const [],
    List<String> pluginKotlinSources = const [],
    List<String> pluginJarDeps = const [],
    List<String> pluginResDirs = const [],
  }) async {
    final aapt2 = await sdkLocator.findAapt2();
    final androidSdk = await sdkLocator.findAndroidSdk();
    final compileSdk = ctx.config.android.compileSdk.isEmpty
        ? '34'
        : ctx.config.android.compileSdk;
    final androidJar = await _resolveAndroidJar(androidSdk, compileSdk);

    final resDir = p.join(ctx.buildDir, 'res');
    // Merge plugin resources into app res tree when present
    for (final pluginRes in pluginResDirs) {
      final src = Directory(pluginRes);
      if (await src.exists()) {
        await _copyDir(src, Directory(resDir));
      }
    }

    // aapt2 compile --dir requires -o to be a compiled-resources ZIP file,
    // not a directory of loose .flat files.
    final compiledResZip = p.join(ctx.buildDir, 'compiled_resources.zip');
    final compiledParent = Directory(p.dirname(compiledResZip));
    if (!await compiledParent.exists()) {
      await compiledParent.create(recursive: true);
    }
    if (await File(compiledResZip).exists()) {
      await File(compiledResZip).delete();
    }

    final compileArgs = buildAapt2CompileDirArgs(
      resDir: resDir,
      compiledResourcesZip: compiledResZip,
    );
    final compile = await Process.run(aapt2, compileArgs);
    if (compile.exitCode != 0) {
      throw Exception('aapt2 compile failed: ${compile.stderr}');
    }
    if (!await File(compiledResZip).exists()) {
      throw Exception(
        'aapt2 compile did not produce compiled-resources zip at $compiledResZip',
      );
    }

    final linkedRes = p.join(ctx.buildDir, 'resources.ap_');
    final genDir = p.join(ctx.buildDir, 'gen');
    await Directory(genDir).create(recursive: true);
    final manifestPath = p.join(ctx.buildDir, 'AndroidManifest.xml');

    // Assets are merged later via stageApkLayout; avoid -A placeholder issues.
    final linkArgs = buildAapt2LinkArgs(
      androidJar: androidJar,
      manifestPath: manifestPath,
      outputAp: linkedRes,
      compiledResourcesZip: compiledResZip,
      javaOutDir: genDir,
    );

    final link = await Process.run(aapt2, linkArgs);
    if (link.exitCode != 0) {
      throw Exception('aapt2 link failed: ${link.stderr}');
    }

    // javac + kotlinc for host + all plugin sources
    final javac = await sdkLocator.findJavac();
    final classesDir = p.join(ctx.buildDir, 'classes');
    if (await Directory(classesDir).exists()) {
      await Directory(classesDir).delete(recursive: true);
    }
    await Directory(classesDir).create(recursive: true);

    final javaFiles = <String>[...pluginJavaSources];
    await for (final e in Directory(hostDir).list(recursive: true)) {
      if (e is File && e.path.endsWith('.java')) javaFiles.add(e.path);
    }
    await for (final e in Directory(genDir).list(recursive: true)) {
      if (e is File && e.path.endsWith('.java')) javaFiles.add(e.path);
    }

    final cpSep = Platform.isWindows ? ';' : ':';
    final classpathEntries = <String>[
      androidJar,
      embeddingJar,
      ...androidxJars,
      ...pluginJarDeps,
    ];
    final classpath = classpathEntries.join(cpSep);

    // Kotlin first (produces .class for Java to see)
    if (pluginKotlinSources.isNotEmpty) {
      final kotlinc = await sdkLocator.findKotlinc();
      if (kotlinc == null) {
        throw Exception(
          'Kotlin sources present (${pluginKotlinSources.length}) but kotlinc '
          'not found. Run: oka get kotlin',
        );
      }
      final kotlinEnv = await _kotlinJavaEnvironment();
      final kotlinCp = classpath;
      // Pass Java sources as stubs so Kotlin can resolve mutual references
      // (common with Pigeon-generated Java next to Kotlin).
      final ktArgs = <String>[
        '-classpath',
        kotlinCp,
        '-d',
        classesDir,
        '-jvm-target',
        '${ctx.config.android.javaVersion}',
        ...pluginKotlinSources,
        // Java files for type resolution only (javac emits real bytecode next)
        ...javaFiles,
      ];
      final ktResult = await Process.run(
        kotlinc,
        ktArgs,
        environment: kotlinEnv,
      );
      if (ktResult.exitCode != 0) {
        throw Exception(
          'kotlinc failed: ${ktResult.stderr}\n${ktResult.stdout}',
        );
      }
    }

    if (javaFiles.isNotEmpty) {
      // Include classesDir so Java sees Kotlin output
      final javaCp = '$classpath$cpSep$classesDir';
      final javacResult = await Process.run(javac, [
        '-classpath',
        javaCp,
        '-d',
        classesDir,
        '--release',
        '${ctx.config.android.javaVersion}',
        ...javaFiles,
      ]);
      if (javacResult.exitCode != 0) {
        throw Exception('javac failed: ${javacResult.stderr}');
      }
    }

    // jar + d8
    final classesJar = p.join(ctx.buildDir, 'classes.jar');
    final jarResult = await Process.run('jar', [
      'cf',
      classesJar,
      '-C',
      classesDir,
      '.',
    ]);
    if (jarResult.exitCode != 0) {
      throw Exception('jar failed: ${jarResult.stderr}');
    }

    final d8 = await sdkLocator.findD8();
    final dexOutDir = p.join(ctx.buildDir, 'dex');
    await Directory(dexOutDir).create(recursive: true);

    // Prefer newer build-tools d8 (35+) for embedding + large classpaths.
    // Compile-only jars (annotations) go to --lib, not into the program DEX.
    final programJars = <String>[
      classesJar,
      embeddingJar,
      ..._filterRuntimeJars([...androidxJars, ...pluginJarDeps]),
    ];
    final compileOnlyJars = <String>[
      ..._filterCompileOnlyJars([...androidxJars, ...pluginJarDeps]),
    ];
    final minApi = ctx.config.android.minSdk.isEmpty
        ? '21'
        : ctx.config.android.minSdk;
    final d8Args = <String>[
      '--output',
      dexOutDir,
      '--min-api',
      minApi,
      '--lib',
      androidJar,
      for (final lib in compileOnlyJars) ...['--lib', lib],
      ...programJars,
    ];
    if (verbose) {
      print(
        '   d8 program jars: ${programJars.length}, '
        'lib jars: ${compileOnlyJars.length + 1}',
      );
    }
    final d8Result = await Process.run(d8, d8Args);
    if (d8Result.exitCode != 0) {
      // Retry without extra --lib jars (older d8)
      final d8Result2 = await Process.run(d8, [
        '--output',
        dexOutDir,
        '--min-api',
        minApi,
        '--lib',
        androidJar,
        ...programJars,
      ]);
      if (d8Result2.exitCode != 0) {
        throw Exception('d8 failed: ${d8Result2.stderr}');
      }
    }

    final dexFiles = await listDexOutputs(dexOutDir);
    if (dexFiles.isEmpty) {
      throw Exception('d8 produced no classes*.dex under $dexOutDir');
    }
    if (verbose) {
      print('   d8 multi-dex: ${dexFiles.map(p.basename).join(', ')}');
    }
    return dexFiles;
  }

  Future<String> _packageAndSign({
    required BuildContext ctx,
    required List<String> dexFiles,
    required String flutterAssetsDir,
    required Map<String, String> libflutterByAbi,
    required Map<String, String> libappByAbi,
    Map<String, List<String>> extraNativeByAbi = const {},
  }) async {
    final staging = p.join(ctx.buildDir, 'staging');
    final resourcesApk = p.join(ctx.buildDir, 'resources.ap_');

    // Stage plugin natives alongside libflutter
    final mergedFlutter = Map<String, String>.from(libflutterByAbi);
    await stageApkLayout(
      stagingDir: staging,
      dexFiles: dexFiles,
      flutterAssetsDir: flutterAssetsDir,
      libflutterByAbi: mergedFlutter,
      libappByAbi: libappByAbi,
      resourcesApk: await File(resourcesApk).exists() ? resourcesApk : null,
    );
    for (final entry in extraNativeByAbi.entries) {
      final abi = normalizeAbi(entry.key);
      for (final so in entry.value) {
        final dest = File(p.join(staging, 'lib', abi, p.basename(so)));
        await dest.parent.create(recursive: true);
        await File(so).copy(dest.path);
      }
    }

    final unsigned = p.join(ctx.buildDir, 'app-${ctx.mode.name}-unsigned.apk');
    await zipStagingToApk(staging, unsigned);

    // zipalign + apksigner
    final zipalign = await sdkLocator.findZipalign();
    final apksigner = await sdkLocator.findApksigner();
    final aligned = p.join(ctx.buildDir, 'app-${ctx.mode.name}-aligned.apk');
    final signed = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');

    final za = await Process.run(zipalign, [
      '-f',
      // -p: page-align uncompressed .so; 4: required for stored resources.arsc
      // (targetSdk >= 30 rejects compressed/misaligned resources.arsc).
      '-p',
      '4',
      unsigned,
      aligned,
    ]);
    if (za.exitCode != 0) {
      throw Exception('zipalign failed: ${za.stderr}');
    }

    final ks = await _debugKeystore();
    final sign = await Process.run(apksigner, [
      'sign',
      '--ks',
      ks,
      '--ks-pass',
      'pass:android',
      '--out',
      signed,
      aligned,
    ]);
    if (sign.exitCode != 0) {
      throw Exception('apksigner failed: ${sign.stderr}');
    }
    return signed;
  }

  /// Jars that should be desugared into the APK (runtime).
  ///
  /// Dedupes by Maven artifact identity (group:artifact), keeping the highest
  /// version so d8 does not see duplicate types (e.g. kotlin-stdlib 1.9 vs 2.0).
  List<String> _filterRuntimeJars(List<String> jars) {
    final best = <String, ({String path, String version})>{};
    for (final j in jars) {
      final base = p.basename(j).toLowerCase();
      if (_isCompileOnlyJarName(base)) continue;
      try {
        if (File(j).lengthSync() <= 200) continue;
      } catch (_) {
        continue;
      }
      final id = _artifactKey(j);
      final ver = _artifactVersion(j);
      final prev = best[id];
      if (prev == null || _compareVersions(ver, prev.version) > 0) {
        best[id] = (path: j, version: ver);
      }
    }
    return best.values.map((e) => e.path).toList();
  }

  /// `.../group/path/artifact/version/file.jar` → `group.path:baseArtifact`
  ///
  /// Strips KMP suffixes (`-android`, `-jvm`, `-ktx`) so
  /// `lifecycle-runtime` and `lifecycle-runtime-android` collapse.
  String _artifactKey(String jarPath) {
    final parts = p.split(jarPath);
    // expect .../maven/<group>/<artifact>/<version>/<file>
    if (parts.length >= 4) {
      final version = parts[parts.length - 2];
      var artifact = parts[parts.length - 3];
      artifact = artifact.replaceAll(RegExp(r'-(android|jvm|ktx)$'), '');
      final groupParts = <String>[];
      for (var i = parts.length - 4; i >= 0; i--) {
        if (parts[i] == 'maven' || parts[i] == 'cache') break;
        groupParts.insert(0, parts[i]);
      }
      if (groupParts.isNotEmpty) {
        return '${groupParts.join('.')}:$artifact';
      }
      return '$artifact@$version';
    }
    return p.basename(jarPath);
  }

  String _artifactVersion(String jarPath) {
    final parts = p.split(jarPath);
    if (parts.length >= 2) return parts[parts.length - 2];
    return '0';
  }

  int _compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .split(RegExp(r'[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map(int.parse)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  List<String> _filterCompileOnlyJars(List<String> jars) {
    final out = <String>[];
    final seen = <String>{};
    for (final j in jars) {
      final base = p.basename(j).toLowerCase();
      if (!_isCompileOnlyJarName(base)) continue;
      if (!seen.add(base)) continue;
      out.add(j);
    }
    return out;
  }

  bool _isCompileOnlyJarName(String base) {
    return base.contains('annotation') ||
        base.contains('annotations') ||
        base.contains('jspecify') ||
        base.startsWith('kotlin-stdlib-common') ||
        base.contains('animal-sniffer') ||
        base.contains('checker-qual');
  }

  /// Prefer Java 17/21 for kotlinc — Kotlin 2.1 rejects JDK 25 version strings.
  Future<Map<String, String>> _kotlinJavaEnvironment() async {
    final env = Map<String, String>.from(Platform.environment);
    final candidates = <String>[
      if (env['JAVA_HOME'] != null) env['JAVA_HOME']!,
      '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home',
      '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',
      '/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home',
      '/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',
      p.join(
        Platform.environment['HOME'] ?? '',
        '.sdkman',
        'candidates',
        'java',
        'current',
      ),
    ];
    for (final home in candidates) {
      if (home.isEmpty) continue;
      final javaBin = p.join(home, 'bin', 'java');
      if (!await File(javaBin).exists()) continue;
      // Reject JDK 25+ for kotlinc 2.1
      final ver = await Process.run(javaBin, ['-version']);
      final text = '${ver.stderr}${ver.stdout}';
      final m = RegExp(r'version "(\d+)').firstMatch(text);
      final major = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
      if (major >= 17 && major <= 22) {
        env['JAVA_HOME'] = home;
        env['PATH'] = '${p.join(home, 'bin')}:${env['PATH'] ?? ''}';
        if (verbose) print('   kotlinc JAVA_HOME=$home (java $major)');
        return env;
      }
    }
    return env;
  }

  Future<void> _copyDir(Directory source, Directory dest) async {
    await dest.create(recursive: true);
    await for (final e in source.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: source.path);
      final out = p.join(dest.path, rel);
      if (e is Directory) {
        await Directory(out).create(recursive: true);
      } else if (e is File) {
        await File(out).parent.create(recursive: true);
        await e.copy(out);
      }
    }
  }

  Future<String> _debugKeystore() async {
    final home = Platform.environment['HOME'] ?? '';
    final path = p.join(home, '.android', 'debug.keystore');
    if (await File(path).exists()) return path;
    await Directory(p.dirname(path)).create(recursive: true);
    final r = await Process.run('keytool', [
      '-genkey',
      '-v',
      '-keystore',
      path,
      '-storepass',
      'android',
      '-alias',
      'androiddebugkey',
      '-keypass',
      'android',
      '-keyalg',
      'RSA',
      '-keysize',
      '2048',
      '-validity',
      '10000',
      '-dname',
      'CN=Android Debug,O=Android,C=US',
    ]);
    if (r.exitCode != 0) {
      throw Exception('keytool failed: ${r.stderr}');
    }
    return path;
  }
}
