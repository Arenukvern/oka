import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../build/aab_layout.dart';
import '../build/aapt2_commands.dart';
import '../build/apk_layout.dart';
import '../build/sdk_locator.dart';
import '../signing_config.dart';

/// Outcome of [compileAndDex].
class CompileDexOutcome {

  const CompileDexOutcome({
    required this.ok,
    this.error,
    this.dexFiles = const [],
  });
  final bool ok;
  final String? error;
  final List<String> dexFiles;
}

/// aapt2 compile/link + kotlinc/javac + d8.
///
/// Extracted from FlutterApkBuilder so pipeline steps and custom pipelines
/// share one implementation (ADR-0002).
Future<CompileDexOutcome> compileAndDex({
  required final BuildContext ctx,
  required final SdkLocator sdkLocator,
  required final String hostDir,
  required final String embeddingJar,
  required final List<String> androidxJarPaths,
  final List<String> pluginJavaSources = const [],
  final List<String> pluginKotlinSources = const [],
  final List<String> pluginJarDeps = const [],
  final List<String> pluginResDirs = const [],
  final List<String> resourceConfigs = const [],
  final String? versionCode,
  final String? versionName,
  final int? javaVersionOverride,
}) async {
  try {
    final aapt2 = await sdkLocator.findAapt2();
    final androidSdk = await sdkLocator.findAndroidSdk();
    final compileSdk = ctx.config.android.compileSdk.isEmpty
        ? '34'
        : ctx.config.android.compileSdk;
    final androidJar = await resolveAndroidJar(androidSdk, compileSdk);

    final resDir = p.join(ctx.buildDir, 'res');
    // Merge plugin resources into app res tree when present
    for (final pluginRes in pluginResDirs) {
      final src = Directory(pluginRes);
      if (await src.exists()) {
        await copyDirectory(src, Directory(resDir));
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
      return CompileDexOutcome(
        ok: false,
        error: 'aapt2 compile failed: ${compile.stderr}',
      );
    }
    if (!await File(compiledResZip).exists()) {
      return CompileDexOutcome(
        ok: false,
        error:
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
      resourceConfigs: resourceConfigs,
      versionCode: versionCode,
      versionName: versionName,
    );

    final link = await Process.run(aapt2, linkArgs);
    if (link.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'aapt2 link failed: ${link.stderr}',
      );
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
      ...androidxJarPaths,
      ...pluginJarDeps,
    ];
    final classpath = classpathEntries.join(cpSep);

    // Kotlin first (produces .class for Java to see)
    if (pluginKotlinSources.isNotEmpty) {
      final kotlinc = await sdkLocator.findKotlinc();
      if (kotlinc == null) {
        return CompileDexOutcome(
          ok: false,
          error:
              'Kotlin sources present (${pluginKotlinSources.length}) but kotlinc '
              'not found. Run: oka get kotlin',
        );
      }
      final kotlinEnv = await kotlinJavaEnvironment(verbose: ctx.verbose);
      // Pass Java sources as stubs so Kotlin can resolve mutual references
      // (common with Pigeon-generated Java next to Kotlin).
      final ktArgs = <String>[
        '-classpath',
        classpath,
        '-d',
        classesDir,
        '-jvm-target',
        '${javaVersionOverride ?? ctx.config.android.javaVersion}',
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
        return CompileDexOutcome(
          ok: false,
          error: 'kotlinc failed: ${ktResult.stderr}\n${ktResult.stdout}',
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
        '${javaVersionOverride ?? ctx.config.android.javaVersion}',
        ...javaFiles,
      ]);
      if (javacResult.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'javac failed: ${javacResult.stderr}',
        );
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
      return CompileDexOutcome(
        ok: false,
        error: 'jar failed: ${jarResult.stderr}',
      );
    }

    final d8 = await sdkLocator.findD8();
    final dexOutDir = p.join(ctx.buildDir, 'dex');
    // d8 appends part files (classes2.dex…) — stale parts from earlier runs
    // with different classpath sizes would otherwise accumulate into the APK.
    final dexDir = Directory(dexOutDir);
    if (await dexDir.exists()) await dexDir.delete(recursive: true);
    await Directory(dexOutDir).create(recursive: true);

    // Prefer newer build-tools d8 (35+) for embedding + large classpaths.
    // Compile-only jars (annotations) go to --lib, not into the program DEX.
    // ADR-0007 determinism: dependency resolution runs in parallel, so the
    // jar order varies between runs — and d8 partitions classes into
    // classesN.dex in argument order. Sorting makes the multi-dex split
    // (part count + content distribution) reproducible byte-for-byte.
    final programJars = [
      classesJar,
      embeddingJar,
      ...filterRuntimeJars([...androidxJarPaths, ...pluginJarDeps]),
    ]..sort();
    final compileOnlyJars = filterCompileOnlyJars([
      ...androidxJarPaths,
      ...pluginJarDeps,
    ])..sort();
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

    if (ctx.verbose) {
      print(
        '   d8 program jars: ${programJars.length}, '
        'lib jars: ${compileOnlyJars.length + 1}',
      );
    }
    var d8Result = await Process.run(d8, d8Args);
    if (d8Result.exitCode != 0) {
      // Retry without extra --lib jars (older d8)
      d8Result = await Process.run(d8, [
        '--output',
        dexOutDir,
        '--min-api',
        minApi,
        '--lib',
        androidJar,
        ...programJars,
      ]);
      if (d8Result.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'd8 failed: ${d8Result.stderr}',
        );
      }
    }

    final dexFiles = await listDexOutputs(dexOutDir);
    if (dexFiles.isEmpty) {
      return CompileDexOutcome(
        ok: false,
        error: 'd8 produced no classes*.dex under $dexOutDir',
      );
    }
    if (ctx.verbose) {
      print('   d8 multi-dex: ${dexFiles.map(p.basename).join(', ')}');
    }
    return CompileDexOutcome(ok: true, dexFiles: dexFiles);
  } on Exception catch (e) {
    return CompileDexOutcome(ok: false, error: e.toString());
  }
}

/// aapt2 compile + **proto-format** link + kotlinc/javac + d8 (AAB path).
///
/// Same compile/dex behavior as [compileAndDex]; the link step emits proto
/// resources (`resources.pb` + protobuf manifest) consumed by the bundle
/// packager. Returns dex files; proto output lands at `resources_proto.ap_`.
Future<CompileDexOutcome> compileAndDexProto({
  required final BuildContext ctx,
  required final SdkLocator sdkLocator,
  required final String hostDir,
  required final String embeddingJar,
  required final List<String> androidxJarPaths,
  final List<String> pluginJavaSources = const [],
  final List<String> pluginKotlinSources = const [],
  final List<String> pluginJarDeps = const [],
  final List<String> pluginResDirs = const [],
  final List<String> resourceConfigs = const [],
  final String? versionCode,
  final String? versionName,
  final int? javaVersionOverride,
}) async {
  try {
    final aapt2 = await sdkLocator.findAapt2();
    final androidSdk = await sdkLocator.findAndroidSdk();
    final compileSdk = ctx.config.android.compileSdk.isEmpty
        ? '34'
        : ctx.config.android.compileSdk;
    final androidJar = await resolveAndroidJar(androidSdk, compileSdk);

    final resDir = p.join(ctx.buildDir, 'res');
    for (final pluginRes in pluginResDirs) {
      final src = Directory(pluginRes);
      if (await src.exists()) {
        await copyDirectory(src, Directory(resDir));
      }
    }

    final compiledResZip = p.join(ctx.buildDir, 'compiled_resources.zip');
    final compiledParent = Directory(p.dirname(compiledResZip));
    if (!await compiledParent.exists()) {
      await compiledParent.create(recursive: true);
    }
    if (await File(compiledResZip).exists()) {
      await File(compiledResZip).delete();
    }

    final compile = await Process.run(
      aapt2,
      buildAapt2CompileDirArgs(
        resDir: resDir,
        compiledResourcesZip: compiledResZip,
      ),
    );
    if (compile.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'aapt2 compile failed: ${compile.stderr}',
      );
    }
    if (!await File(compiledResZip).exists()) {
      return CompileDexOutcome(
        ok: false,
        error:
            'aapt2 compile did not produce compiled-resources zip at $compiledResZip',
      );
    }

    final linkedRes = p.join(ctx.buildDir, 'resources_proto.ap_');
    final genDir = p.join(ctx.buildDir, 'gen');
    await Directory(genDir).create(recursive: true);
    final manifestPath = p.join(ctx.buildDir, 'AndroidManifest.xml');

    final link = await Process.run(
      aapt2,
      buildAapt2LinkProtoFormatArgs(
        androidJar: androidJar,
        manifestPath: manifestPath,
        outputAp: linkedRes,
        compiledResourcesZip: compiledResZip,
        javaOutDir: genDir,
        resourceConfigs: resourceConfigs,
        versionCode: versionCode,
        versionName: versionName,
      ),
    );
    if (link.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'aapt2 link --proto-format failed: ${link.stderr}',
      );
    }

    return await _compileJavaAndDex(
      ctx: ctx,
      javaVersionOverride: javaVersionOverride,
      sdkLocator: sdkLocator,
      hostDir: hostDir,
      embeddingJar: embeddingJar,
      androidxJarPaths: androidxJarPaths,
      pluginJavaSources: pluginJavaSources,
      pluginKotlinSources: pluginKotlinSources,
      pluginJarDeps: pluginJarDeps,
      androidJar: androidJar,
      genDir: genDir,
    );
  } on Exception catch (e) {
    return CompileDexOutcome(ok: false, error: e.toString());
  }
}

/// Shared javac/kotlinc/jar/d8 tail used by both APK and AAB compile paths.
Future<CompileDexOutcome> _compileJavaAndDex({
  required final BuildContext ctx,
  required final SdkLocator sdkLocator, required final String hostDir, required final String embeddingJar, required final List<String> androidxJarPaths, required final String androidJar, required final String genDir, final int? javaVersionOverride,
  final List<String> pluginJavaSources = const [],
  final List<String> pluginKotlinSources = const [],
  final List<String> pluginJarDeps = const [],
}) async {
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
    ...androidxJarPaths,
    ...pluginJarDeps,
  ];
  final classpath = classpathEntries.join(cpSep);

  if (pluginKotlinSources.isNotEmpty) {
    final kotlinc = await sdkLocator.findKotlinc();
    if (kotlinc == null) {
      return CompileDexOutcome(
        ok: false,
        error:
            'Kotlin sources present (${pluginKotlinSources.length}) but kotlinc '
            'not found. Run: oka get kotlin',
      );
    }
    final kotlinEnv = await kotlinJavaEnvironment(verbose: ctx.verbose);
    final ktArgs = <String>[
      '-classpath',
      classpath,
      '-d',
      classesDir,
      '-jvm-target',
      '${javaVersionOverride ?? ctx.config.android.javaVersion}',
      ...pluginKotlinSources,
      ...javaFiles,
    ];
    final ktResult = await Process.run(kotlinc, ktArgs, environment: kotlinEnv);
    if (ktResult.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'kotlinc failed: ${ktResult.stderr}\n${ktResult.stdout}',
      );
    }
  }

  if (javaFiles.isNotEmpty) {
    final javaCp = '$classpath$cpSep$classesDir';
    final javacResult = await Process.run(javac, [
      '-classpath',
      javaCp,
      '-d',
      classesDir,
      '--release',
      '${javaVersionOverride ?? ctx.config.android.javaVersion}',
      ...javaFiles,
    ]);
    if (javacResult.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'javac failed: ${javacResult.stderr}',
      );
    }
  }

  final classesJar = p.join(ctx.buildDir, 'classes.jar');
  final jarResult = await Process.run('jar', [
    'cf',
    classesJar,
    '-C',
    classesDir,
    '.',
  ]);
  if (jarResult.exitCode != 0) {
    return CompileDexOutcome(
      ok: false,
      error: 'jar failed: ${jarResult.stderr}',
    );
  }

  final d8 = await sdkLocator.findD8();
  final dexOutDir = p.join(ctx.buildDir, 'dex');
  // d8 appends part files (classes2.dex…) — stale parts from earlier runs
  // with different classpath sizes would otherwise accumulate into the APK.
  final dexDir = Directory(dexOutDir);
  if (await dexDir.exists()) await dexDir.delete(recursive: true);
  await Directory(dexOutDir).create(recursive: true);

  final programJars = <String>[
    classesJar,
    embeddingJar,
    ...filterRuntimeJars([...androidxJarPaths, ...pluginJarDeps]),
  ];
  final compileOnlyJars = filterCompileOnlyJars([
    ...androidxJarPaths,
    ...pluginJarDeps,
  ]);
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

  var d8Result = await Process.run(d8, d8Args);
  if (d8Result.exitCode != 0) {
    d8Result = await Process.run(d8, [
      '--output',
      dexOutDir,
      '--min-api',
      minApi,
      '--lib',
      androidJar,
      ...programJars,
    ]);
    if (d8Result.exitCode != 0) {
      return CompileDexOutcome(
        ok: false,
        error: 'd8 failed: ${d8Result.stderr}',
      );
    }
  }

  final dexFiles = await listDexOutputs(dexOutDir);
  if (dexFiles.isEmpty) {
    return CompileDexOutcome(
      ok: false,
      error: 'd8 produced no classes*.dex under $dexOutDir',
    );
  }
  return CompileDexOutcome(ok: true, dexFiles: dexFiles);
}

/// Stage layout → zip → zipalign → apksigner. Returns signed APK path.
Future<String> packageAndSign({
  required final BuildContext ctx,
  required final SdkLocator sdkLocator,
  required final List<String> dexFiles,
  required final String flutterAssetsDir,
  required final Map<String, String> libflutterByAbi,
  required final Map<String, String> libappByAbi,
  final Map<String, List<String>> extraNativeByAbi = const {},
  final SigningConfig? signing,
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

  // Signing: project release keystore when configured (ADR-0006 G2),
  // otherwise the oka debug keystore (development only).
  final configured = signing ?? await SigningConfig.autoResolve(ctx) ?? const SigningConfig();
  final List<String> signArgs;
  if (configured.isConfigured) {
    print('🔐 Signing with configured keystore: ${configured.keyAlias}');
    signArgs = [
      'sign',
      '--ks',
      configured.keystorePath,
      '--ks-pass',
      'pass:${configured.storePassword}',
      '--ks-key-alias',
      configured.keyAlias,
      '--key-pass',
      'pass:${configured.effectiveKeyPassword}',
      '--out',
      signed,
      aligned,
    ];
  } else {
    if (ctx.mode.isRelease) {
      print(
        '⚠️  No signing configuration found (android/key.properties or '
        'oka.yaml android.signing) — falling back to the DEBUG keystore.\n'
        '   Store uploads will be rejected; configure signing for releases.',
      );
    }
    final ks = await debugKeystore();
    signArgs = [
      'sign',
      '--ks',
      ks,
      '--ks-pass',
      'pass:android',
      '--out',
      signed,
      aligned,
    ];
  }
  final sign = await Process.run(apksigner, signArgs);
  if (sign.exitCode != 0) {
    throw Exception('apksigner failed: ${sign.stderr}');
  }
  return signed;
}

/// Prefer configured compile SDK platform; fall back to highest installed.
Future<String> resolveAndroidJar(final String androidSdk, final String compileSdk) async {
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

/// Jars that should be desugared into the APK (runtime).
///
/// Dedupes by Maven artifact identity (group:artifact), keeping the highest
/// version so d8 does not see duplicate types (e.g. kotlin-stdlib 1.9 vs 2.0).
List<String> filterRuntimeJars(final List<String> jars) {
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
  return best.values.map((final e) => e.path).toList();
}

/// `.../group/path/artifact/version/file.jar` → `group.path:baseArtifact`
///
/// Strips KMP suffixes (`-android`, `-jvm`, `-ktx`) so
/// `lifecycle-runtime` and `lifecycle-runtime-android` collapse.
String _artifactKey(final String jarPath) {
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

String _artifactVersion(final String jarPath) {
  final parts = p.split(jarPath);
  if (parts.length >= 2) return parts[parts.length - 2];
  return '0';
}

int _compareVersions(final String a, final String b) {
  List<int> parse(final String v) => v
      .split(RegExp('[^0-9]+'))
      .where((final s) => s.isNotEmpty)
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

List<String> filterCompileOnlyJars(final List<String> jars) {
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

bool _isCompileOnlyJarName(final String base) => base.contains('annotation') ||
      base.contains('annotations') ||
      base.contains('jspecify') ||
      base.startsWith('kotlin-stdlib-common') ||
      base.contains('animal-sniffer') ||
      base.contains('checker-qual');

/// Prefer Java 17/21 for kotlinc — Kotlin 2.1 rejects JDK 25 version strings.
Future<Map<String, String>> kotlinJavaEnvironment({
  final bool verbose = false,
}) async {
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

Future<void> copyDirectory(final Directory source, final Directory dest) async {
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

/// Stage `base/` module → zip → jarsigner (v1). Returns signed AAB path.
Future<String> packageAndSignAab({
  required final BuildContext ctx,
  required final SdkLocator sdkLocator,
  required final List<String> dexFiles,
  required final String flutterAssetsDir,
  required final Map<String, String> libflutterByAbi,
  required final Map<String, String> libappByAbi,
  final Map<String, List<String>> extraNativeByAbi = const {},
  final SigningConfig? signing,
}) async {
  final baseDir = p.join(ctx.buildDir, 'aab', 'base');
  final protoRes = p.join(ctx.buildDir, 'resources_proto.ap_');

  await stageAabBaseModule(
    baseDir: baseDir,
    protoResourcesAp: protoRes,
    dexFiles: dexFiles,
    flutterAssetsDir: flutterAssetsDir,
    libflutterByAbi: libflutterByAbi,
    libappByAbi: libappByAbi,
    extraNativeByAbi: extraNativeByAbi,
  );

  final bundleRoot = p.dirname(baseDir);
  // Bundle-level metadata required by the App Bundle format spec.
  await File(
    p.join(bundleRoot, 'BundleConfig.pb'),
  ).writeAsBytes(minimalBundleConfigPb(), flush: true);
  final unsigned = p.join(bundleRoot, 'app-${ctx.mode.name}-unsigned.aab');
  await zipBundle(bundleRoot, unsigned);

  // v1 JAR signing — apksigner does not sign bundles (ADR-0004).
  final configured = signing ?? await SigningConfig.autoResolve(ctx) ?? const SigningConfig();
  final ks = configured.isConfigured
      ? configured.keystorePath
      : await debugKeystore();
  if (!configured.isConfigured && ctx.mode.isRelease) {
    print(
      '⚠️  No signing configuration found — signing the AAB with the DEBUG '
      'keystore. Store uploads will be rejected.',
    );
  }
  final signed = p.join(bundleRoot, 'app-${ctx.mode.name}.aab');
  final jarsigner = await _findJarsigner(sdkLocator);
  await signAab(
    unsignedAabPath: unsigned,
    keystorePath: ks,
    keyAlias: configured.isConfigured
        ? configured.keyAlias
        : 'androiddebugkey',
    storePass: configured.isConfigured
        ? configured.storePassword
        : 'android',
    signedAabPath: signed,
    jarsignerPath: jarsigner,
  );
  return signed;
}

/// Locate jarsigner: next to javac first, then PATH.
Future<String?> _findJarsigner(final SdkLocator sdkLocator) async {
  try {
    final javac = await sdkLocator.findJavac();
    final candidate = p.join(p.dirname(javac), 'jarsigner');
    if (await File(candidate).exists()) return candidate;
  } catch (_) {
    // javac unavailable; fall through to PATH lookup below.
  }
  try {
    final r = await Process.run('which', ['jarsigner']);
    if (r.exitCode == 0) return (r.stdout as String).trim();
  } catch (_) {}
  return null;
}

Future<String> debugKeystore() async {
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
