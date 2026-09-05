import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Expected native ABI directory names inside an Android APK.
const kSupportedAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];

/// Maps oka / Flutter ABI names to APK `lib/<abi>/` directory names.
String normalizeAbi(String abi) {
  switch (abi.toLowerCase().trim()) {
    case 'android-arm64':
    case 'arm64':
    case 'arm64-v8a':
    case 'aarch64':
      return 'arm64-v8a';
    case 'android-arm':
    case 'arm':
    case 'armeabi-v7a':
    case 'armv7':
      return 'armeabi-v7a';
    case 'android-x64':
    case 'x64':
    case 'x86_64':
      return 'x86_64';
    case 'android-x86':
    case 'x86':
      return 'x86';
    default:
      return abi;
  }
}

/// Resolves the list of ABIs to package from config lists + optional target.
///
/// If [targetAbi] is non-empty, it is used alone (after normalization).
/// Otherwise [configAbis] is used; if empty, defaults to `arm64-v8a`.
List<String> resolveAbis({
  required List<String> configAbis,
  String targetAbi = '',
}) {
  if (targetAbi.trim().isNotEmpty) {
    return [normalizeAbi(targetAbi)];
  }
  if (configAbis.isEmpty) {
    return ['arm64-v8a'];
  }
  final seen = <String>{};
  final result = <String>[];
  for (final raw in configAbis) {
    final abi = normalizeAbi(raw);
    if (seen.add(abi)) {
      result.add(abi);
    }
  }
  return result.isEmpty ? ['arm64-v8a'] : result;
}

/// Maps APK ABI to Flutter engine artifact directory name (debug).
String engineArtifactDirForAbi(String abi, {required bool release}) {
  final n = normalizeAbi(abi);
  final suffix = release ? '-release' : '';
  switch (n) {
    case 'arm64-v8a':
      return 'android-arm64$suffix';
    case 'armeabi-v7a':
      return 'android-arm$suffix';
    case 'x86_64':
      return 'android-x64$suffix';
    case 'x86':
      return 'android-x86$suffix';
    default:
      return 'android-arm64$suffix';
  }
}

/// Describes files that must appear in a complete Flutter APK layout.
class ApkLayoutSpec {
  final bool requireDex;
  final bool requireFlutterAssets;
  final List<String> abis;
  final bool requireLibapp;

  const ApkLayoutSpec({
    this.requireDex = true,
    this.requireFlutterAssets = true,
    this.abis = const ['arm64-v8a'],
    this.requireLibapp = false,
  });
}

/// Result of validating an APK (zip) or a staging directory layout.
class ApkLayoutValidation {
  final bool ok;
  final List<String> missing;
  final List<String> present;

  const ApkLayoutValidation({
    required this.ok,
    required this.missing,
    required this.present,
  });
}

/// Collect relative paths under [root] (posix-style).
Future<Set<String>> listRelativePaths(Directory root) async {
  final paths = <String>{};
  if (!await root.exists()) {
    return paths;
  }
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final rel = p.relative(entity.path, from: root.path);
      paths.add(rel.replaceAll(r'\', '/'));
    }
  }
  return paths;
}

/// Validates a staging directory that mirrors APK internal paths.
Future<ApkLayoutValidation> validateStagingLayout(
  String stagingDir, {
  ApkLayoutSpec spec = const ApkLayoutSpec(),
}) async {
  final paths = await listRelativePaths(Directory(stagingDir));
  return validatePathSet(paths, spec: spec);
}

/// Validates paths already listed (e.g. from `unzip -l`).
ApkLayoutValidation validatePathSet(
  Iterable<String> paths, {
  ApkLayoutSpec spec = const ApkLayoutSpec(),
}) {
  final normalized = paths.map((e) => e.replaceAll(r'\', '/')).toSet();
  final missing = <String>[];
  final present = <String>[];

  void check(String label, bool Function() ok) {
    if (ok()) {
      present.add(label);
    } else {
      missing.add(label);
    }
  }

  if (spec.requireDex) {
    check(
      'classes.dex',
      () =>
          normalized.contains('classes.dex') ||
          normalized.any((p) => p.endsWith('/classes.dex')),
    );
  }
  // Multi-dex: if any classesN.dex was staged, all should be present in path set
  // (callers validate explicit multi-dex via validatePathSet with full listing).

  if (spec.requireFlutterAssets) {
    check(
      'assets/flutter_assets/',
      () => normalized.any(
        (p) =>
            p == 'assets/flutter_assets' ||
            p.startsWith('assets/flutter_assets/'),
      ),
    );
  }

  for (final abi in spec.abis.map(normalizeAbi)) {
    final so = 'lib/$abi/libflutter.so';
    check(
      so,
      () =>
          normalized.contains(so) ||
          normalized.any((p) => p.endsWith('/lib/$abi/libflutter.so')),
    );
    if (spec.requireLibapp) {
      final appSo = 'lib/$abi/libapp.so';
      check(
        appSo,
        () =>
            normalized.contains(appSo) ||
            normalized.any((p) => p.endsWith('/lib/$abi/libapp.so')),
      );
    }
  }

  return ApkLayoutValidation(
    ok: missing.isEmpty,
    missing: missing,
    present: present,
  );
}

/// Collect all multi-dex outputs from a d8 directory (`classes.dex`,
/// `classes2.dex`, …). Sorted so `classes.dex` comes first.
Future<List<String>> listDexOutputs(String dexDir) async {
  final dir = Directory(dexDir);
  if (!await dir.exists()) return const [];
  final files = <String>[];
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final name = p.basename(e.path);
    if (name == 'classes.dex' || RegExp(r'^classes\d+\.dex$').hasMatch(name)) {
      files.add(e.path);
    }
  }
  files.sort((a, b) {
    final na = p.basename(a);
    final nb = p.basename(b);
    if (na == 'classes.dex') return -1;
    if (nb == 'classes.dex') return 1;
    return na.compareTo(nb);
  });
  return files;
}

/// Stage files into an APK-shaped directory tree (before zip/aapt packaging).
///
/// Copies:
/// - [dexFile] / [dexFiles] → APK root as `classes.dex`, `classes2.dex`, …
/// - [flutterAssetsDir] → `assets/flutter_assets/`
/// - per-ABI `libflutter.so` from [libflutterByAbi]
/// - optional per-ABI `libapp.so` from [libappByAbi]
Future<void> stageApkLayout({
  required String stagingDir,
  String? dexFile,
  List<String> dexFiles = const [],
  String? flutterAssetsDir,
  Map<String, String> libflutterByAbi = const {},
  Map<String, String> libappByAbi = const {},
  String? resourcesApk,
}) async {
  final root = Directory(stagingDir);
  if (await root.exists()) {
    await root.delete(recursive: true);
  }
  await root.create(recursive: true);

  final allDex = <String>[if (dexFile != null) dexFile, ...dexFiles];
  // Preserve multi-dex names (classes.dex, classes2.dex, …)
  for (final dex in allDex) {
    final src = File(dex);
    if (!await src.exists()) continue;
    final name = p.basename(dex);
    final destName =
        (name == 'classes.dex' || RegExp(r'^classes\d+\.dex$').hasMatch(name))
        ? name
        : 'classes.dex';
    await src.copy(p.join(stagingDir, destName));
  }

  if (flutterAssetsDir != null) {
    final srcDir = Directory(flutterAssetsDir);
    if (await srcDir.exists()) {
      final dest = Directory(p.join(stagingDir, 'assets', 'flutter_assets'));
      await _copyDirectory(srcDir, dest);
    }
  }

  for (final entry in libflutterByAbi.entries) {
    final abi = normalizeAbi(entry.key);
    final src = File(entry.value);
    if (await src.exists()) {
      final dest = File(p.join(stagingDir, 'lib', abi, 'libflutter.so'));
      await dest.parent.create(recursive: true);
      await src.copy(dest.path);
    }
  }

  for (final entry in libappByAbi.entries) {
    final abi = normalizeAbi(entry.key);
    final src = File(entry.value);
    if (await src.exists()) {
      final dest = File(p.join(stagingDir, 'lib', abi, 'libapp.so'));
      await dest.parent.create(recursive: true);
      await src.copy(dest.path);
    }
  }

  // Optional: explode resources.ap_ (zip) into staging for manual packaging.
  if (resourcesApk != null && await File(resourcesApk).exists()) {
    final bytes = await File(resourcesApk).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (!file.isFile) continue;
      final outPath = p.join(stagingDir, file.name);
      await File(outPath).parent.create(recursive: true);
      await File(outPath).writeAsBytes(file.content as List<int>);
    }
  }
}

/// Build an unsigned APK zip from a staging directory (no aapt2 required).
///
/// Used for unit tests and as a last-mile packager when resources are already
/// linked. Real device installs still need proper aapt2-linked resources when
/// using Android framework resource IDs.
Future<void> zipStagingToApk(String stagingDir, String apkPath) async {
  final archive = Archive();
  final root = Directory(stagingDir);
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: stagingDir).replaceAll(r'\', '/');
    final data = await entity.readAsBytes();
    // resources.arsc must be STORED (uncompressed) and 4-byte aligned for
    // targetSdk >= 30 installs; compression here causes install failure -124.
    final file = ArchiveFile(rel, data.length, data)
      ..compress = rel != 'resources.arsc';
    archive.addFile(file);
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw StateError('Failed to encode APK zip from $stagingDir');
  }
  await File(apkPath).parent.create(recursive: true);
  await File(apkPath).writeAsBytes(encoded, flush: true);
}

/// Read entry names from an APK/zip file.
Future<List<String>> listApkEntries(String apkPath) async {
  final bytes = await File(apkPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  return archive
      .where((f) => f.isFile)
      .map((f) => f.name.replaceAll(r'\', '/'))
      .toList();
}

/// Extract multi-dex entry names from an APK listing (`classes.dex`,
/// `classes2.dex`, …).
List<String> multiDexEntries(Iterable<String> apkPaths) {
  return apkPaths
      .map((e) => e.replaceAll(r'\', '/'))
      .where(
        (e) =>
            e == 'classes.dex' || RegExp(r'(^|/)classes\d+\.dex$').hasMatch(e),
      )
      .map((e) => e.contains('/') ? e.split('/').last : e)
      .toSet()
      .toList()
    ..sort((a, b) {
      if (a == 'classes.dex') return -1;
      if (b == 'classes.dex') return 1;
      return a.compareTo(b);
    });
}

/// Search raw DEX bytes for a UTF-8 needle (class descriptors often appear
/// as plain strings, e.g. `Lio/flutter/plugins/GeneratedPluginRegistrant;`).
bool dexBytesContainString(List<int> dexBytes, String needle) {
  if (needle.isEmpty) return false;
  final n = needle.codeUnits;
  if (n.length > dexBytes.length) return false;
  outer:
  for (var i = 0; i <= dexBytes.length - n.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (dexBytes[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Convert Java FQCN to a DEX type descriptor used in string tables.
String javaClassToDexDescriptor(String fullyQualifiedClass) {
  return 'L${fullyQualifiedClass.replaceAll('.', '/')};';
}

/// True if any of the given DEX blobs contains [fullyQualifiedClass].
bool anyDexContainsClass(
  Iterable<List<int>> dexBlobs,
  String fullyQualifiedClass,
) {
  final desc = javaClassToDexDescriptor(fullyQualifiedClass);
  final simple = fullyQualifiedClass.split('.').last;
  for (final blob in dexBlobs) {
    if (dexBytesContainString(blob, desc) ||
        dexBytesContainString(blob, fullyQualifiedClass) ||
        dexBytesContainString(blob, simple)) {
      return true;
    }
  }
  return false;
}

/// Read all multi-dex blobs from an APK zip.
Future<Map<String, List<int>>> readApkDexBlobs(String apkPath) async {
  final bytes = await File(apkPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final out = <String, List<int>>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = f.name.replaceAll(r'\', '/').split('/').last;
    if (name == 'classes.dex' || RegExp(r'^classes\d+\.dex$').hasMatch(name)) {
      out[name] = List<int>.from(f.content as List<int>);
    }
  }
  return out;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    final destPath = p.join(destination.path, relativePath);
    if (entity is File) {
      await File(destPath).parent.create(recursive: true);
      await entity.copy(destPath);
    } else if (entity is Directory) {
      await Directory(destPath).create(recursive: true);
    }
  }
}
