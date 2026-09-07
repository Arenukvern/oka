/// Self-resolving build helpers (ADR-0007): automatic detection and
/// remediation with loud notices and env escapes.
///
/// Design law: these are services/steps, never YAML fields. Escapes are
/// environment variables or flags.
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'build/sdk_locator.dart';

/// Set when automatic tool installation should be suppressed.
const noAutoInstallEnv = 'OKA_NO_AUTO_INSTALL';

bool get autoInstallEnabled =>
    Platform.environment[noAutoInstallEnv] != '1';

/// Ensures the Kotlin compiler is available, downloading it into
/// `~/.oka/tools` when missing. Returns true when kotlinc is usable.
///
/// (Logic relocated from the CLI `oka get kotlin` so builds can self-heal;
/// the CLI command delegates here.)
Future<bool> ensureKotlinc({final bool verbose = false}) async {
  final existing = await SdkLocator().findKotlinc();
  if (existing != null) return true;
  if (!autoInstallEnabled) {
    if (verbose) {
      print('   auto-install disabled ($noAutoInstallEnv) — skipping kotlin');
    }
    return false;
  }
  print('🛠️  kotlinc not found — auto-installing (escape: $noAutoInstallEnv=1)');
  try {
    await installKotlinCompiler(verbose: verbose);
    return await SdkLocator().findKotlinc() != null;
  } on Exception catch (e) {
    print('⚠️  Kotlin auto-install failed: $e');
    print('   Run manually: oka get kotlin');
    return false;
  }
}

/// Installs the Kotlin compiler under `~/.oka/tools` (ADR-0007 shared
/// installer used by both the build self-heal and `oka get kotlin`).
Future<void> installKotlinCompiler({final bool verbose = false}) =>
    _installKotlinCompiler(verbose: verbose);

Future<void> _installKotlinCompiler({final bool verbose = false}) async {
  final homeDir =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (homeDir.isEmpty) throw Exception('Could not determine home directory');

  const kotlinVersion = '2.1.0';
  final okaToolsDir = p.join(homeDir, '.oka', 'tools');
  await Directory(okaToolsDir).create(recursive: true);
  final kotlinDir = p.join(okaToolsDir, 'kotlin-$kotlinVersion');

  if (await Directory(kotlinDir).exists()) {
    return; // downloaded but not on PATH; SdkLocator finds it there
  }

  const downloadUrl =
      'https://github.com/JetBrains/kotlin/releases/download/v$kotlinVersion/kotlin-compiler-$kotlinVersion.zip';

  // Provision the compiler zip through the shared artifact store
  // (ADR-0013) so `oka cache list/gc` sees it and OKA_CACHE can share it.
  final store = LocalArtifactStore();
  final zipFile = await store.fetch(
    ContentKey.compute(
      category: 'kotlin-compiler',
      name: 'kotlin-compiler',
      version: kotlinVersion,
      inputs: const [downloadUrl],
    ),
    () async {
      final tmp = await Directory.systemTemp.createTemp('oka_kotlin_');
      final tempFile = p.join(tmp.path, 'kotlin-compiler.zip');
      final download = await Process.run('curl', [
        '-L',
        '-o',
        tempFile,
        downloadUrl,
      ], runInShell: true);
      if (download.exitCode != 0) {
        throw Exception('Failed to download Kotlin: ${download.stderr}');
      }
      return File(tempFile);
    },
  );

  print('📦 Extracting Kotlin compiler from ${zipFile.path}...');
  final extract = await Process.run('unzip', [
    '-q',
    zipFile.path,
    '-d',
    okaToolsDir,
  ], runInShell: true);
  if (extract.exitCode != 0) {
    throw Exception('Failed to extract Kotlin: ${extract.stderr}');
  }

  final extractedDir = p.join(okaToolsDir, 'kotlinc');
  if (await Directory(extractedDir).exists()) {
    await Directory(extractedDir).rename(kotlinDir);
  }

  if (!Platform.isWindows) {
    await Process.run('chmod', ['+x', p.join(kotlinDir, 'bin', 'kotlinc')]);
  }
  if (verbose) print('   Kotlin $kotlinVersion installed at $kotlinDir');
}

/// Highest `sourceCompatibility JavaVersion.VERSION_NN` (or
/// `sourceCompatibility "NN"`) declared in any of [gradleFiles]; null when
/// nothing declares one.
int? detectRequiredJavaLevel(final Iterable<String> gradleFiles) {
  var maxLevel = 0;
  for (final file in gradleFiles) {
    if (!File(file).existsSync()) continue;
    final text = File(file).readAsStringSync();
    // Matches `JavaVersion.VERSION_17`, `VERSION_21`, etc.
    for (final m in RegExp('VERSION_([0-9]+)', caseSensitive: false).allMatches(text)) {
      final level = int.tryParse(m.group(1)!) ?? 0;
      if (level > maxLevel) maxLevel = level;
    }
    // Matches `sourceCompatibility = "17"` / `sourceCompatibility 17`.
    for (final m in RegExp("sourceCompatibility\\s*=?\\s*['\"]?(\\d+)")
        .allMatches(text)) {
      final level = int.tryParse(m.group(1)!) ?? 0;
      if (level > maxLevel) maxLevel = level;
    }
  }
  return maxLevel == 0 ? null : maxLevel;
}

/// Effective javac source/target: config version raised to the detected
/// plugin maximum, with a printed notice when bumped.
int effectiveJavaLevel({
  required final int configVersion,
  final Iterable<String> pluginGradleFiles = const [],
  final void Function(String message)? onBump,
}) {
  final detected = detectRequiredJavaLevel(pluginGradleFiles);
  if (detected != null && detected > configVersion) {
    onBump?.call(
      'java_version raised $configVersion → $detected '
      '(plugin sources require it)',
    );
    return detected;
  }
  return configVersion;
}

/// Resolves Android (versionCode, versionName): explicit `oka.yaml`
/// `version_code`/`version_name` wins, otherwise the app `pubspec.yaml`
/// `version: x.y.z+nn`.
({int versionCode, String versionName}) resolveAndroidVersion(
  final String projectPath, {
  required final int configVersionCode,
  required final String configVersionName,
}) {
  if (configVersionCode != 0 && configVersionName.isNotEmpty) {
    return (versionCode: configVersionCode, versionName: configVersionName);
  }
  final pubspec = File(p.join(projectPath, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return (versionCode: configVersionCode, versionName: configVersionName);
  }
  final doc = loadYaml(pubspec.readAsStringSync());
  final raw = doc is Map ? doc['version']?.toString() : null;
  if (raw == null) {
    return (versionCode: configVersionCode, versionName: configVersionName);
  }
  final plus = raw.indexOf('+');
  final name = plus < 0 ? raw : raw.substring(0, plus);
  final code = plus >= 0 ? int.tryParse(raw.substring(plus + 1)) ?? 0 : 0;
  return (
    versionCode: configVersionCode != 0 ? configVersionCode : code,
    versionName: configVersionName.isNotEmpty ? configVersionName : name,
  );
}

/// Names declared under `dev_dependencies` in [projectPath]/pubspec.yaml.
Set<String> devDependencyNames(final String projectPath) {
  final file = File(p.join(projectPath, 'pubspec.yaml'));
  if (!file.existsSync()) return const {};
  try {
    final doc = loadYaml(file.readAsStringSync());
    final dev = doc is Map ? doc['dev_dependencies'] : null;
    if (dev is! Map) return const {};
    return dev.keys.map((final k) => k.toString()).toSet();
  } on YamlException {
    return const {};
  }
}
