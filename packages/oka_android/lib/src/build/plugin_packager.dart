import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import 'dependency_cache.dart';
import 'gradle_dep_parser.dart';
import 'host_codegen.dart';
import 'plugin_discovery.dart';
import 'toolchain.dart';

/// Declared Maven inputs for one plugin (ADR-0008).
class PluginDeclaredDeps {

  const PluginDeclaredDeps({
    required this.rootCoords,
    required this.extraRepos,
  });
  final List<MavenCoordinate> rootCoords;
  final List<String> extraRepos;
}

/// Result of packaging one Flutter Android plugin for no-Gradle APK builds.
class PackagedPlugin {

  const PackagedPlugin({
    required this.plugin,
    this.javaSources = const [],
    this.kotlinSources = const [],
    this.jarDeps = const [],
    this.nativeLibs = const [],
    this.nativeLibsByAbi = const {},
    this.resDirs = const [],
    this.manifestPaths = const [],
    this.packable = true,
    this.failureReason,
  });
  final DiscoveredPlugin plugin;
  final List<String> javaSources;
  final List<String> kotlinSources;
  final List<String> jarDeps;
  final List<String> nativeLibs; // paths to .so files (any abi; staged later)
  final Map<String, List<String>> nativeLibsByAbi; // abi -> .so paths
  final List<String> resDirs;
  final List<String> manifestPaths;
  final bool packable;
  final String? failureReason;

  bool get hasSources => javaSources.isNotEmpty || kotlinSources.isNotEmpty;
  bool get hasNative => nativeLibsByAbi.isNotEmpty || nativeLibs.isNotEmpty;

  PluginRegistration? get registration {
    final q = plugin.qualifiedClass;
    if (q == null) return null;
    return PluginRegistration(className: q, name: plugin.name);
  }
}

/// Aggregate packaging result for all plugins in a project.
class PluginPackagingResult {

  const PluginPackagingResult({
    required this.plugins,
    required this.failed,
    required this.registrations,
    required this.allJavaSources,
    required this.allKotlinSources,
    required this.allJarDeps,
    required this.nativeLibsByAbi,
    required this.resDirs,
    required this.manifestPaths,
  });
  final List<PackagedPlugin> plugins;
  final List<PackagedPlugin> failed;
  final List<PluginRegistration> registrations;
  final List<String> allJavaSources;
  final List<String> allKotlinSources;
  final List<String> allJarDeps;
  final Map<String, List<String>> nativeLibsByAbi;
  final List<String> resDirs;
  final List<String> manifestPaths;

  bool get allSucceeded => failed.isEmpty;
}

/// Collects sources, Maven deps, resources, and native libs for Flutter plugins.
class PluginPackager {

  PluginPackager({
    required this.dependencyCache,
    required final ResolvedToolchain sdkLocator,
    this.verbose = false,
    this.allowNetwork = true,
  }) : toolchain = sdkLocator;
  final DependencyCache dependencyCache;

  /// Resolved toolchain (ADR-0013 T1). The constructor parameter stays
  /// named `sdkLocator` for source compatibility with call sites outside
  /// this migration wave (`oka explain`); the type is the injectable
  /// [ResolvedToolchain].
  final ResolvedToolchain toolchain;
  final bool verbose;
  final bool allowNetwork;

  /// Package all Android plugins from [discovery].
  ///
  /// When [requireAll] is true (default strict), any packable-required plugin
  /// that cannot be prepared is listed in [PluginPackagingResult.failed].
  Future<PluginPackagingResult> packageAll(
    final PluginDiscoveryResult discovery, {
    required final String buildDir,
    required final List<String> abis,
    final bool requireAll = true,
  }) async {
    final packaged = <PackagedPlugin>[];
    final failed = <PackagedPlugin>[];
    final regs = <PluginRegistration>[];
    final java = <String>[];
    final kotlin = <String>[];
    final jars = <String>{};
    final natives = <String, List<String>>{};
    final resDirs = <String>[];
    final manifests = <String>[];

    // Package plugins concurrently (bounded): dependency resolution dominates
    // packaging time and parallelizes safely (DependencyCache de-duplicates
    // shared coordinates). Results are merged in discovery order below.
    final plugins = discovery.androidPlugins;
    final results = List<PackagedPlugin?>.filled(plugins.length, null);
    const poolSize = 4;
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor;
        if (i >= plugins.length) return;
        cursor++;
        results[i] = await packageOne(
          plugins[i],
          workDir: p.join(buildDir, 'plugins', plugins[i].name),
          abis: abis,
        );
      }
    }

    // Zero-plugin projects (pure Dart UI over engine classes) must build:
    // clamp(1, 0) is an invalid argument, so guard the pool size.
    if (plugins.isNotEmpty) {
      await Future.wait(
        List.generate(poolSize.clamp(1, plugins.length), (_) => worker()),
      );
    }

    for (var i = 0; i < plugins.length; i++) {
      final plugin = plugins[i];
      final result = results[i]!;
      packaged.add(result);
      if (!result.packable) {
        // Dart-only Android plugins (no pluginClass, no sources) are OK.
        if (plugin.pluginClass == null &&
            !result.hasSources &&
            result.failureReason == null) {
          if (verbose) {
            print('   ${plugin.name}: dart-only (no Android host class)');
          }
          continue;
        }
        // ffiPlugin without host class still may need natives
        if (result.failureReason != null) {
          failed.add(result);
        }
        continue;
      }

      java.addAll(result.javaSources);
      kotlin.addAll(result.kotlinSources);
      jars.addAll(result.jarDeps);
      resDirs.addAll(result.resDirs);
      manifests.addAll(result.manifestPaths);
      result.nativeLibsByAbi.forEach((final abi, final paths) {
        natives.putIfAbsent(abi, () => []).addAll(paths);
      });
      final reg = result.registration;
      if (reg != null) regs.add(reg);
    }

    return PluginPackagingResult(
      plugins: packaged,
      failed: failed,
      registrations: regs,
      allJavaSources: java,
      allKotlinSources: kotlin,
      allJarDeps: jars.toList(),
      nativeLibsByAbi: natives,
      resDirs: resDirs,
      manifestPaths: manifests,
    );
  }

  /// Declared Maven inputs for one plugin (ADR-0008): gradle-parsed root
  /// coordinates after conditional dedup (gradle default branch wins, printed
  /// notice), plugin-declared repos, and the kotlin/androidx bootstrap set
  /// (kotlin set gated on [hasKotlinSources]). Shared by [packageOne] and the
  /// `oka explain --deps` dependency plan so both see identical inputs.
  Future<PluginDeclaredDeps> collectDeclaredDeps(
    final DiscoveredPlugin plugin, {
    required final bool hasKotlinSources,
  }) async {
    final path = plugin.path;
    final gradleFiles = await _findGradleFiles(path);
    final extraRepos = <String>[];
    final rootCoords = <MavenCoordinate>[];
    // Conditional-dep dedup (ADR-0007): collect all parsed deps across the
    // plugin's gradle files, re-mapping per-file if/else group ids so groups
    // from different files cannot collide.
    final allDeps = <ParsedGradleDep>[];
    const groupIdStride = 100000;
    for (var fi = 0; fi < gradleFiles.length; fi++) {
      final gf = gradleFiles[fi];
      final text = await File(gf).readAsString();
      extraRepos.addAll(parseMavenRepositoryUrls(text));
      for (final dep in parseGradleDependencies(text)) {
        allDeps.add(
          dep.conditionalGroup > 0
              ? ParsedGradleDep(
                  groupId: dep.groupId,
                  artifactId: dep.artifactId,
                  version: dep.version,
                  configuration: dep.configuration,
                  inConditional: true,
                  conditionalGroup: fi * groupIdStride + dep.conditionalGroup,
                )
              : dep,
        );
      }
    }
    final keptDeps = dedupeConditionalDeps(
      allDeps,
      pluginName: plugin.name,
      onNotice: print,
    );
    for (final dep in keptDeps) {
      final packaging = await _guessPackaging(dep);
      rootCoords.add(MavenCoordinate(
        groupId: dep.groupId,
        artifactId: dep.artifactId,
        version: dep.version,
        packaging: packaging,
      ));
    }
    // Always pull kotlin stdlib + coroutines-core when any Kotlin sources exist
    if (hasKotlinSources) {
      rootCoords.add(const MavenCoordinate(
        groupId: 'org.jetbrains.kotlin',
        artifactId: 'kotlin-stdlib',
        version: '2.0.21',
      ));
      rootCoords.add(const MavenCoordinate(
        groupId: 'org.jetbrains.kotlinx',
        artifactId: 'kotlinx-coroutines-core-jvm',
        version: '1.10.2',
      ));
      rootCoords.add(const MavenCoordinate(
        groupId: 'org.jetbrains.kotlinx',
        artifactId: 'kotlinx-coroutines-android',
        version: '1.10.2',
      ));
      // Common AndroidX KMP shells → ensure android variants are pulled
      rootCoords.add(const MavenCoordinate(
        groupId: 'androidx.datastore',
        artifactId: 'datastore-preferences-android',
        version: '1.1.7',
        packaging: 'aar',
      ));
      rootCoords.add(const MavenCoordinate(
        groupId: 'androidx.datastore',
        artifactId: 'datastore-core-android',
        version: '1.1.7',
        packaging: 'aar',
      ));
    }
    // Bootstrap classpath for typical Flutter Android plugins
    rootCoords.addAll(const [
      MavenCoordinate(
        groupId: 'androidx.annotation',
        artifactId: 'annotation-jvm',
        version: '1.9.1',
      ),
      MavenCoordinate(
        groupId: 'androidx.core',
        artifactId: 'core',
        version: '1.13.1',
        packaging: 'aar',
      ),
      MavenCoordinate(
        groupId: 'org.jetbrains',
        artifactId: 'annotations',
        version: '24.1.0',
      ),
    ]);
    return PluginDeclaredDeps(rootCoords: rootCoords, extraRepos: extraRepos);
  }

  /// Whether a plugin declares Kotlin host sources (gates the kotlin
  /// bootstrap dependency set).
  Future<bool> hasKotlinSources(final DiscoveredPlugin plugin) async {
    final kt = await _findSources(plugin.path, ['.kt']);
    return kt.isNotEmpty;
  }

  /// Package a single plugin: sources, deps, res, natives.
  Future<PackagedPlugin> packageOne(
    final DiscoveredPlugin plugin, {
    required final String workDir,
    required final List<String> abis,
  }) async {
    await Directory(workDir).create(recursive: true);
    final path = plugin.path;
    if (path.isEmpty || !await Directory(path).exists()) {
      return PackagedPlugin(
        plugin: plugin,
        packable: false,
        failureReason: 'plugin path missing: $path',
      );
    }

    final javaSources = await _findSources(path, ['.java']);
    final kotlinSources = await _findSources(path, ['.kt']);
    // Exclude test sources
    final javaMain = javaSources.where((final s) => !_isTestPath(s)).toList();
    final ktMain = kotlinSources.where((final s) => !_isTestPath(s)).toList();

    final jarDeps = <String>[];
    // Declared Maven inputs (ADR-0008): shared with the `oka explain --deps`
    // dry-run plan so packaging and the plan cannot disagree.
    final declared = await collectDeclaredDeps(
      plugin,
      hasKotlinSources: ktMain.isNotEmpty,
    );
    final extraRepos = declared.extraRepos;
    final rootCoords = declared.rootCoords;
    if (rootCoords.isNotEmpty) {
      try {
        final resolved = await dependencyCache.resolveWithTransitives(
          rootCoords,
          extraRepos: extraRepos,
        );
        jarDeps.addAll(resolved.map((final r) => r.jarPath));
      } catch (e) {
        if (verbose) {
          print('   ⚠️  ${plugin.name}: dependency resolve issues: $e');
        }
      }
    }

    final resDirs = <String>[];
    final resMain = p.join(path, 'android', 'src', 'main', 'res');
    if (await Directory(resMain).exists()) resDirs.add(resMain);

    final manifests = <String>[];
    final man = p.join(path, 'android', 'src', 'main', 'AndroidManifest.xml');
    if (await File(man).exists()) manifests.add(man);

    // Prebuilt .so under jni/ or libs/
    final nativesByAbi = <String, List<String>>{};
    await _collectPrebuiltNatives(path, nativesByAbi);

    // jni / cmake native build
    final needsNative = plugin.name == 'jni' ||
        await File(p.join(path, 'src', 'CMakeLists.txt')).exists() ||
        await _gradleHasExternalNativeBuild(path);

    if (needsNative && nativesByAbi.isEmpty) {
      try {
        final built = await buildCmakeNative(
          pluginPath: path,
          workDir: p.join(workDir, 'native'),
          abis: abis,
        );
        built.forEach((final abi, final soPath) {
          nativesByAbi.putIfAbsent(abi, () => []).add(soPath);
        });
      } catch (e) {
        return PackagedPlugin(
          plugin: plugin,
          javaSources: javaMain,
          kotlinSources: ktMain,
          jarDeps: jarDeps,
          resDirs: resDirs,
          manifestPaths: manifests,
          packable: false,
          failureReason: 'native build failed for ${plugin.name}: $e',
        );
      }
    }

    // Plugins with no Android sources and no pluginClass are dart-only
    if (javaMain.isEmpty &&
        ktMain.isEmpty &&
        plugin.pluginClass == null &&
        nativesByAbi.isEmpty) {
      return PackagedPlugin(
        plugin: plugin,
      );
    }

    // Must have sources if we have a pluginClass to register
    if (plugin.pluginClass != null && javaMain.isEmpty && ktMain.isEmpty) {
      return PackagedPlugin(
        plugin: plugin,
        packable: false,
        failureReason:
            '${plugin.name}: pluginClass ${plugin.pluginClass} but no Java/Kotlin sources found',
      );
    }

    // Generate BuildConfig for plugins that reference it
    final buildConfigSources = <String>[];
    final pkg = plugin.androidPackage;
    if (pkg != null && pkg.isNotEmpty) {
      final bc = await _writeBuildConfig(
        workDir: workDir,
        packageName: pkg,
        debuggable: true,
      );
      buildConfigSources.add(bc);
    }

    if (verbose) {
      print(
        '   ${plugin.name}: java=${javaMain.length} kt=${ktMain.length} '
        'jars=${jarDeps.length} natives=${nativesByAbi.values.fold<int>(0, (final a, final b) => a + b.length)}',
      );
    }

    return PackagedPlugin(
      plugin: plugin,
      javaSources: [...javaMain, ...buildConfigSources],
      kotlinSources: ktMain,
      jarDeps: jarDeps,
      nativeLibsByAbi: nativesByAbi,
      resDirs: resDirs,
      manifestPaths: manifests,
    );
  }

  /// Minimal AGP-compatible BuildConfig for plugin sources that reference it.
  Future<String> _writeBuildConfig({
    required final String workDir,
    required final String packageName,
    required final bool debuggable,
  }) async {
    final rel = packageName.replaceAll('.', '/');
    final path = p.join(workDir, 'gen', rel, 'BuildConfig.java');
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString('''
package $packageName;

public final class BuildConfig {
  public static final boolean DEBUG = $debuggable;
  public static final String LIBRARY_PACKAGE_NAME = "$packageName";
  public static final String BUILD_TYPE = "${debuggable ? 'debug' : 'release'}";
  private BuildConfig() {}
}
''');
    return path;
  }

  Future<List<String>> _findSources(final String pluginPath, final List<String> exts) async {
    // Scan entire main trees — Java files often live under kotlin/ (Pigeon).
    final roots = [
      p.join(pluginPath, 'android', 'src', 'main'),
      p.join(pluginPath, 'java', 'src', 'main'),
      p.join(pluginPath, 'android'),
    ];
    final files = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (_isTestPath(e.path)) continue;
        if (exts.any((final x) => e.path.endsWith(x))) {
          files.add(e.path);
        }
      }
    }
    return files.toSet().toList();
  }

  bool _isTestPath(final String path) {
    final n = path.replaceAll(r'\', '/');
    return n.contains('/test/') ||
        n.contains('/androidTest/') ||
        n.contains('/src/test/');
  }

  Future<List<String>> _findGradleFiles(final String pluginPath) async {
    final candidates = [
      p.join(pluginPath, 'android', 'build.gradle'),
      p.join(pluginPath, 'android', 'build.gradle.kts'),
    ];
    final out = <String>[];
    for (final c in candidates) {
      if (await File(c).exists()) out.add(c);
    }
    return out;
  }

  Future<bool> _gradleHasExternalNativeBuild(final String pluginPath) async {
    for (final gf in await _findGradleFiles(pluginPath)) {
      final t = await File(gf).readAsString();
      if (t.contains('externalNativeBuild') || t.contains('cmake')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _collectPrebuiltNatives(
    final String pluginPath,
    final Map<String, List<String>> out,
  ) async {
    final searchRoots = [
      p.join(pluginPath, 'android', 'src', 'main', 'jniLibs'),
      p.join(pluginPath, 'android', 'libs'),
      p.join(pluginPath, 'android', 'src', 'main', 'libs'),
    ];
    for (final root in searchRoots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.so')) {
          // expect .../<abi>/libfoo.so
          final parts = p.split(e.path);
          final abiIdx = parts.length - 2;
          if (abiIdx >= 0) {
            final abi = parts[abiIdx];
            if (['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'].contains(abi)) {
              out.putIfAbsent(abi, () => []).add(e.path);
            }
          }
        }
      }
    }
  }

  Future<String> _guessPackaging(final ParsedGradleDep dep) async {
    // Heuristic: androidx / com.google.android often AAR
    if (dep.groupId.startsWith('androidx.') ||
        dep.groupId.startsWith('com.google.android.') ||
        dep.artifactId.contains('billing') ||
        dep.artifactId.contains('webkit') ||
        dep.artifactId.contains('browser') ||
        dep.artifactId.contains('preference') ||
        dep.artifactId.contains('datastore')) {
      return 'aar';
    }
    if (dep.groupId.startsWith('org.jetbrains.kotlin') ||
        dep.groupId.startsWith('org.jetbrains.annotations')) {
      return 'jar';
    }
    // try aar first then jar in resolve? default aar for android libs
    return 'aar';
  }

  /// Build CMake shared library for a plugin (e.g. jni → libdartjni.so).
  Future<Map<String, String>> buildCmakeNative({
    required final String pluginPath,
    required final String workDir,
    required final List<String> abis,
  }) async {
    final cmakeLists = File(p.join(pluginPath, 'src', 'CMakeLists.txt'));
    if (!await cmakeLists.exists()) {
      // try android path
      final alt = File(p.join(pluginPath, 'android', 'CMakeLists.txt'));
      if (!await alt.exists()) {
        throw Exception('CMakeLists.txt not found under $pluginPath/src');
      }
    }

    final androidSdk = await toolchain.findAndroidSdk();
    final ndk = await findNdkHome(androidSdk);
    if (ndk == null) {
      throw Exception(
        'Android NDK not found under $androidSdk. '
        'Install with: sdkmanager "ndk;27.0.12077973"',
      );
    }

    final cmake = await findCmake(androidSdk);
    if (cmake == null) {
      throw Exception(
        'CMake not found. Install Android SDK cmake or system cmake.',
      );
    }

    final srcDir = p.join(pluginPath, 'src');
    final result = <String, String>{};

    for (final abi in abis) {
      final abiNorm = abi;
      final abiTriple = _ndkAbiTriple(abiNorm);
      final outDir = p.join(workDir, abiNorm);
      await Directory(outDir).create(recursive: true);

      final ndkToolchain = p.join(
        ndk,
        'build',
        'cmake',
        'android.toolchain.cmake',
      );
      if (!await File(ndkToolchain).exists()) {
        throw Exception('NDK toolchain missing: $ndkToolchain');
      }

      final configure = await Process.run(cmake, [
        '-S',
        srcDir,
        '-B',
        outDir,
        '-DCMAKE_TOOLCHAIN_FILE=$ndkToolchain',
        '-DANDROID_ABI=$abiNorm',
        '-DANDROID_PLATFORM=android-21',
        '-DANDROID_STL=c++_static',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DANDROID=TRUE',
      ]);
      if (configure.exitCode != 0) {
        throw Exception(
          'cmake configure failed for $abiNorm: ${configure.stderr}\n${configure.stdout}',
        );
      }

      final build = await Process.run(cmake, [
        '--build',
        outDir,
        '--config',
        'Release',
        '-j',
        '${Platform.numberOfProcessors}',
      ]);
      if (build.exitCode != 0) {
        throw Exception(
          'cmake build failed for $abiNorm: ${build.stderr}\n${build.stdout}',
        );
      }

      // Find libdartjni.so / *.so
      String? soPath;
      await for (final e in Directory(outDir).list(recursive: true)) {
        if (e is File && e.path.endsWith('.so')) {
          soPath = e.path;
          // prefer dartjni
          if (p.basename(e.path).contains('dartjni') ||
              p.basename(e.path) == 'libdartjni.so') {
            soPath = e.path;
            break;
          }
        }
      }
      if (soPath == null) {
        throw Exception('No .so produced for ABI $abiNorm under $outDir');
      }
      result[abiNorm] = soPath;
      if (verbose) {
        print('   native $abiNorm ($abiTriple): $soPath');
      }
    }
    return result;
  }
}

String _ndkAbiTriple(final String abi) {
  switch (abi) {
    case 'arm64-v8a':
      return 'aarch64-linux-android';
    case 'armeabi-v7a':
      return 'armv7a-linux-androideabi';
    case 'x86_64':
      return 'x86_64-linux-android';
    case 'x86':
      return 'i686-linux-android';
    default:
      return abi;
  }
}

/// Locate NDK under Android SDK.
Future<String?> findNdkHome(final String androidSdk) async {
  final env = Platform.environment['ANDROID_NDK_HOME'] ??
      Platform.environment['NDK_HOME'];
  if (env != null && await Directory(env).exists()) return env;

  final ndkRoot = Directory(p.join(androidSdk, 'ndk'));
  if (await ndkRoot.exists()) {
    final versions = <String>[];
    await for (final e in ndkRoot.list()) {
      if (e is Directory) versions.add(p.basename(e.path));
    }
    if (versions.isNotEmpty) {
      versions.sort();
      return p.join(ndkRoot.path, versions.last);
    }
  }
  final bundle = p.join(androidSdk, 'ndk-bundle');
  if (await Directory(bundle).exists()) return bundle;
  return null;
}

/// Locate cmake binary (SDK side-by-side or system).
Future<String?> findCmake(final String androidSdk) async {
  final cmakeRoot = Directory(p.join(androidSdk, 'cmake'));
  if (await cmakeRoot.exists()) {
    final versions = <String>[];
    await for (final e in cmakeRoot.list()) {
      if (e is Directory) versions.add(p.basename(e.path));
    }
    versions.sort();
    for (final v in versions.reversed) {
      final bin = p.join(cmakeRoot.path, v, 'bin', 'cmake');
      if (await File(bin).exists()) return bin;
    }
  }
  try {
    final r = await Process.run('which', ['cmake']);
    if (r.exitCode == 0) return (r.stdout as String).trim();
  } catch (_) {}
  return null;
}
