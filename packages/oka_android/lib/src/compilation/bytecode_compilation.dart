import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../auto_resolve.dart' show ensureR8;
import '../build/apk_layout.dart';
import '../build/r8_tool.dart' show defaultR8KeepRules, r8Command;
import '../build/toolchain.dart';
import 'process_runner.dart';

class CompileDexOutcome {
  const CompileDexOutcome({
    required this.ok,
    this.error,
    this.dexFiles = const [],
    this.shrinkerArtifacts = const {},
  });

  final bool ok;
  final String? error;
  final List<String> dexFiles;
  final Map<String, String> shrinkerArtifacts;
}

class BytecodeTools {
  const BytecodeTools({
    required this.javac,
    required this.d8,
    this.r8,
    this.kotlinc,
    this.jar = 'jar',
  });

  final String javac;
  final String d8;
  final String? r8;
  final String? kotlinc;
  final String jar;
}

class BytecodeCommandPolicy {
  const BytecodeCommandPolicy({required this.pathSeparator});

  factory BytecodeCommandPolicy.host() =>
      BytecodeCommandPolicy(pathSeparator: Platform.isWindows ? ';' : ':');

  final String pathSeparator;

  List<String> compileClasspath({
    required String androidJar,
    required String embeddingJar,
    required List<String> dependencyJars,
  }) => <String>{androidJar, embeddingJar, ...dependencyJars}.toList()..sort();

  List<String> programJars({
    required String classesJar,
    required String embeddingJar,
    required List<String> runtimeJars,
  }) => <String>{classesJar, embeddingJar, ...runtimeJars}.toList()..sort();

  List<String> compileOnlyJars(List<String> dependencyJars) =>
      filterCompileOnlyJars(dependencyJars)..sort();

  List<String> kotlinArgs({
    required List<String> classpath,
    required String classesDir,
    required int javaVersion,
    required List<String> kotlinSources,
    required List<String> javaSources,
  }) => [
    '-classpath',
    classpath.join(pathSeparator),
    '-d',
    classesDir,
    '-jvm-target',
    '$javaVersion',
    ...([...kotlinSources]..sort()),
    ...([...javaSources]..sort()),
  ];

  List<String> javacArgs({
    required List<String> classpath,
    required String classesDir,
    required int javaVersion,
    required List<String> javaSources,
  }) => [
    '-classpath',
    [...classpath, classesDir].join(pathSeparator),
    '-d',
    classesDir,
    '--release',
    '$javaVersion',
    ...([...javaSources]..sort()),
  ];

  List<String> d8Args({
    required String outputDir,
    required String minApi,
    required String androidJar,
    required List<String> programJars,
    required List<String> compileOnlyJars,
  }) => [
    '--output',
    outputDir,
    '--min-api',
    minApi,
    '--lib',
    androidJar,
    for (final jar in compileOnlyJars) ...['--lib', jar],
    ...programJars,
  ];

  /// R8 CLI arguments (verified against R8 9.4.24 `--help`).
  ///
  /// Only documented R8 CLI flags are emitted: `--seeds`/`--usage` outputs
  /// and `--printconfiguration` do **not** exist in the R8 command line
  /// (the correct collective-config output flag is `--pg-conf-output`).
  List<String> r8Args({
    required String outputDir,
    required String minApi,
    required String androidJar,
    required List<String> programJars,
    required List<String> libraryJars,
    required String configFile,
    required String mappingFile,
    required String confOutputFile,
    bool noTreeShaking = false,
    bool noMinification = false,
  }) => [
    '--release',
    '--output',
    outputDir,
    '--min-api',
    minApi,
    '--lib',
    androidJar,
    for (final jar in libraryJars) ...['--lib', jar],
    '--pg-conf',
    configFile,
    '--pg-map-output',
    mappingFile,
    '--pg-conf-output',
    confOutputFile,
    if (noTreeShaking) '--no-tree-shaking',
    if (noMinification) '--no-minification',
    ...programJars,
  ];
}

Future<CompileDexOutcome> compileAndroidBytecode({
  required BuildContext ctx,
  required BytecodeTools tools,
  required String hostDir,
  required String generatedSourcesDir,
  required String androidJar,
  required String embeddingJar,
  required List<String> dependencyJars,
  List<String> pluginJavaSources = const [],
  List<String> pluginKotlinSources = const [],
  int? javaVersionOverride,
  AndroidProcessRunner processRunner = runAndroidProcess,
  BytecodeCommandPolicy? commandPolicy,

  /// Injectable self-heal seam (tests inject `() async => null` so the
  /// release path never touches the network); default = ADR-0007 auto-install.
  Future<String?> Function({bool verbose}) ensureR8Tool = ensureR8,
  Future<Map<String, String>> Function({bool verbose}) environmentLoader =
      kotlinJavaEnvironment,
}) async {
  final policy = commandPolicy ?? BytecodeCommandPolicy.host();
  try {
    final classesDir = p.join(ctx.buildDir, 'classes');
    final classes = Directory(classesDir);
    if (await classes.exists()) await classes.delete(recursive: true);
    await classes.create(recursive: true);

    final javaSources = <String>[...pluginJavaSources];
    await _collectSources(hostDir, '.java', javaSources);
    await _collectSources(generatedSourcesDir, '.java', javaSources);
    final classpath = policy.compileClasspath(
      androidJar: androidJar,
      embeddingJar: embeddingJar,
      dependencyJars: dependencyJars,
    );
    final javaVersion = javaVersionOverride ?? ctx.config.android.javaVersion;

    if (pluginKotlinSources.isNotEmpty) {
      if (tools.kotlinc == null) {
        return CompileDexOutcome(
          ok: false,
          error:
              'Kotlin sources present (${pluginKotlinSources.length}) but '
              'kotlinc not found. Run: oka get kotlin',
        );
      }
      final result = await processRunner(
        tools.kotlinc!,
        policy.kotlinArgs(
          classpath: classpath,
          classesDir: classesDir,
          javaVersion: javaVersion,
          kotlinSources: [...pluginKotlinSources],
          javaSources: javaSources,
        ),
        environment: await environmentLoader(verbose: ctx.verbose),
      );
      if (result.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'kotlinc failed: ${result.stderr}\n${result.stdout}',
        );
      }
    }

    if (javaSources.isNotEmpty) {
      final result = await processRunner(
        tools.javac,
        policy.javacArgs(
          classpath: classpath,
          classesDir: classesDir,
          javaVersion: javaVersion,
          javaSources: javaSources,
        ),
      );
      if (result.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'javac failed: ${result.stderr}',
        );
      }
    }

    final classesJar = p.join(ctx.buildDir, 'classes.jar');
    final jarResult = await processRunner(tools.jar, [
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

    final dexOutput = p.join(ctx.buildDir, 'dex');
    final dexDirectory = Directory(dexOutput);
    if (await dexDirectory.exists()) await dexDirectory.delete(recursive: true);
    await dexDirectory.create(recursive: true);
    final programs = policy.programJars(
      classesJar: classesJar,
      embeddingJar: embeddingJar,
      runtimeJars: filterRuntimeJars(dependencyJars),
    );
    final compileOnly = policy.compileOnlyJars(dependencyJars);
    final minApi = ctx.config.android.minSdk.isEmpty
        ? '21'
        : ctx.config.android.minSdk;
    if (ctx.verbose) {
      print(
        '   d8 program jars: ${programs.length}, '
        'lib jars: ${compileOnly.length + 1}',
      );
    }
    final shrinkerArtifacts = <String, String>{};
    ProcessResult result;
    if (ctx.mode.isRelease) {
      var r8 = tools.r8;
      if (r8 == null || r8.isEmpty) {
        // ADR-0007 self-heal: download the Google Maven R8 jar when allowed.
        final jar = await ensureR8Tool(verbose: ctx.verbose);
        if (jar == null) {
          return const CompileDexOutcome(
            ok: false,
            error:
                'R8 is required for release builds but was not found. '
                'Run: oka get r8',
          );
        }
        r8 = jar;
      }
      final reportsDir = p.join(ctx.buildDir, 'r8');
      await Directory(reportsDir).create(recursive: true);
      final defaultRules = p.join(reportsDir, 'oka-default-rules.pro');
      await File(defaultRules).writeAsString(defaultR8KeepRules);
      // User rules (ADR-0010 `android.proguard_files`, project-relative):
      // missing files fail the build instead of being silently skipped.
      final userRules = <String>[];
      for (final rule in ctx.config.android.proguardFiles) {
        final path = p.isAbsolute(rule) ? rule : p.join(ctx.projectPath, rule);
        if (!await File(path).exists()) {
          return CompileDexOutcome(
            ok: false,
            error: 'proguard rule file not found: $rule (resolved: $path)',
          );
        }
        userRules.add(path);
      }
      final reports = <String, String>{
        'mapping': p.join(reportsDir, 'mapping.txt'),
        'config': p.join(reportsDir, 'configuration.txt'),
        'input_config': defaultRules,
      };
      shrinkerArtifacts.addAll(reports);
      final args = policy.r8Args(
        outputDir: dexOutput,
        minApi: minApi,
        androidJar: androidJar,
        programJars: programs,
        libraryJars: compileOnly,
        configFile: defaultRules,
        mappingFile: reports['mapping']!,
        confOutputFile: reports['config']!,
        // Release shrinks by default; `enable_optimization: false` keeps
        // R8 (mapping + dex) but disables tree-shaking/minification.
        noTreeShaking: !(ctx.config.android.enableOptimization ?? true),
        noMinification: !(ctx.config.android.enableOptimization ?? true),
      );
      result = await processRunner(
        r8Command(r8, args).first,
        r8Command(r8, args).sublist(1),
      );
      if (result.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'r8 failed: ${result.stderr}\n${result.stdout}',
        );
      }
      final missingReports = reports.entries
          .where((entry) => !File(entry.value).existsSync())
          .map((entry) => entry.key)
          .toList();
      if (missingReports.isNotEmpty) {
        return CompileDexOutcome(
          ok: false,
          error: 'r8 produced no ${missingReports.join(', ')} report.',
        );
      }
    } else {
      result = await processRunner(
        tools.d8,
        policy.d8Args(
          outputDir: dexOutput,
          minApi: minApi,
          androidJar: androidJar,
          programJars: programs,
          compileOnlyJars: compileOnly,
        ),
      );
    }
    if (!ctx.mode.isRelease && result.exitCode != 0) {
      // A failed D8 invocation may already have emitted partial multidex files.
      // The fallback must produce its own complete set, never inherit them.
      await dexDirectory.delete(recursive: true);
      await dexDirectory.create(recursive: true);
      result = await processRunner(
        tools.d8,
        policy.d8Args(
          outputDir: dexOutput,
          minApi: minApi,
          androidJar: androidJar,
          programJars: programs,
          compileOnlyJars: const [],
        ),
      );
      if (result.exitCode != 0) {
        return CompileDexOutcome(
          ok: false,
          error: 'd8 failed: ${result.stderr}',
        );
      }
    }
    final dexFiles = await listDexOutputs(dexOutput);
    if (dexFiles.isEmpty) {
      return CompileDexOutcome(
        ok: false,
        error: 'd8 produced no classes*.dex under $dexOutput',
      );
    }
    if (ctx.verbose) {
      print('   d8 multi-dex: ${dexFiles.map(p.basename).join(', ')}');
    }
    return CompileDexOutcome(
      ok: true,
      dexFiles: dexFiles,
      shrinkerArtifacts: shrinkerArtifacts,
    );
  } on Exception catch (error) {
    return CompileDexOutcome(ok: false, error: error.toString());
  }
}

Future<void> _collectSources(
  String directory,
  String extension,
  List<String> output,
) async {
  final root = Directory(directory);
  if (!await root.exists()) return;
  await for (final entry in root.list(recursive: true)) {
    if (entry is File && entry.path.endsWith(extension)) output.add(entry.path);
  }
}

List<String> filterRuntimeJars(List<String> jars) {
  final best = <String, ({String path, String version})>{};
  for (final jar in jars) {
    final base = p.basename(jar).toLowerCase();
    if (_isCompileOnlyJarName(base)) continue;
    try {
      if (File(jar).lengthSync() <= 200) continue;
    } catch (_) {
      continue;
    }
    final key = _artifactKey(jar);
    final version = _artifactVersion(jar);
    final previous = best[key];
    final comparison = previous == null
        ? 1
        : _compareVersions(version, previous.version);
    final preferCandidate =
        previous != null &&
        comparison == 0 &&
        (_prefersPlatformVariant(jar, previous.path) ||
            (!_prefersPlatformVariant(previous.path, jar) &&
                jar.compareTo(previous.path) < 0));
    if (previous == null || comparison > 0 || preferCandidate) {
      best[key] = (path: jar, version: version);
    }
  }
  return best.values.map((entry) => entry.path).toList();
}

List<String> filterCompileOnlyJars(List<String> jars) {
  final output = <String>[];
  final seen = <String>{};
  for (final jar in [...jars]..sort()) {
    final base = p.basename(jar).toLowerCase();
    if (_isCompileOnlyJarName(base) && seen.add(base)) output.add(jar);
  }
  return output;
}

bool _isCompileOnlyJarName(String base) =>
    base.contains('annotation') ||
    base.contains('annotations') ||
    base.contains('jspecify') ||
    base.startsWith('kotlin-stdlib-common') ||
    base.contains('animal-sniffer') ||
    base.contains('checker-qual');

bool _prefersPlatformVariant(String candidate, String current) {
  bool suffixed(String path) {
    final parts = p.split(path);
    if (parts.length < 3) return false;
    final artifact = parts[parts.length - 3];
    return artifact.endsWith('-jvm') || artifact.endsWith('-android');
  }

  return suffixed(candidate) && !suffixed(current);
}

String _artifactKey(String jarPath) {
  final parts = p.split(jarPath);
  if (parts.length >= 4) {
    final version = parts[parts.length - 2];
    var artifact = parts[parts.length - 3];
    artifact = artifact.replaceAll(RegExp(r'-(android|jvm|ktx)$'), '');
    final group = <String>[];
    for (var i = parts.length - 4; i >= 0; i--) {
      if (parts[i] == 'maven' || parts[i] == 'cache') break;
      group.insert(0, parts[i]);
    }
    return group.isNotEmpty
        ? '${group.join('.')}:$artifact'
        : '$artifact@$version';
  }
  return p.basename(jarPath);
}

String _artifactVersion(String jarPath) {
  final parts = p.split(jarPath);
  return parts.length >= 2 ? parts[parts.length - 2] : '0';
}

int _compareVersions(String left, String right) {
  List<int> parse(String value) => value
      .split(RegExp('[^0-9]+'))
      .where((part) => part.isNotEmpty)
      .map(int.parse)
      .toList();
  final a = parse(left);
  final b = parse(right);
  final count = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < count; i++) {
    final comparison = (i < a.length ? a[i] : 0).compareTo(
      i < b.length ? b[i] : 0,
    );
    if (comparison != 0) return comparison;
  }
  return 0;
}

Future<Map<String, String>> kotlinJavaEnvironment({
  bool verbose = false,
}) async {
  final environment = Map<String, String>.from(Platform.environment);
  final candidates = <String>[
    if (environment['JAVA_HOME'] != null) environment['JAVA_HOME']!,
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
    final java = p.join(home, 'bin', 'java');
    if (!await File(java).exists()) continue;
    final version = await Process.run(java, ['-version']);
    final match = RegExp(
      r'version \"(\d+)',
    ).firstMatch('${version.stderr}${version.stdout}');
    final major = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
    if (major >= 17 && major <= 22) {
      environment['JAVA_HOME'] = home;
      environment['PATH'] =
          '${p.join(home, 'bin')}:${environment['PATH'] ?? ''}';
      if (verbose) print('   kotlinc JAVA_HOME=$home (java $major)');
      return environment;
    }
  }
  return environment;
}

Future<BytecodeTools> resolveBytecodeTools(
  ResolvedToolchain toolchain, {
  required bool needsKotlin,
  bool needsR8 = false,
}) async => BytecodeTools(
  javac: await toolchain.findJavac(),
  d8: await toolchain.findD8(),
  r8: needsR8 ? await toolchain.findR8() : null,
  kotlinc: needsKotlin ? await toolchain.findKotlinc() : null,
);
