import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// App Bundle layout helpers (ADR-0004).
///
/// An `.aab` is a zip whose entries live under a module directory (`base/`):
///
/// ```
/// base/AndroidManifest.xml      (protobuf, from aapt2 --proto-format)
/// base/resources.pb
/// base/res/**                   (compiled resources)
/// base/dex/classes*.dex
/// base/lib/<abi>/*.so
/// base/assets/flutter_assets/**
/// ```
///
/// Unlike APKs, bundles are signed with **v1 JAR signing** (jarsigner);
/// apksigner does not sign bundles.

/// Stage an AAB `base/` module directory.
///
/// - [protoResourcesAp] — output of `aapt2 link --proto-format`; its entries
///   (AndroidManifest.xml, resources.pb, res/**) explode into `base/`.
/// - [dexFiles] — copied to `base/dex/` preserving classesN.dex names.
/// - [flutterAssetsDir] → `base/assets/flutter_assets/`.
/// - [libflutterByAbi] / [libappByAbi] / [extraNativeByAbi] → `base/lib/<abi>/`.
Future<void> stageAabBaseModule({
  required String baseDir,
  required String protoResourcesAp,
  List<String> dexFiles = const [],
  String? flutterAssetsDir,
  Map<String, String> libflutterByAbi = const {},
  Map<String, String> libappByAbi = const {},
  Map<String, List<String>> extraNativeByAbi = const {},
}) async {
  final root = Directory(baseDir);
  if (await root.exists()) {
    await root.delete(recursive: true);
  }
  await root.create(recursive: true);

  // Proto-format resources archive explodes directly into base/.
  final bytes = await File(protoResourcesAp).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    if (!file.isFile) continue;
    final outPath = p.join(baseDir, file.name);
    await File(outPath).parent.create(recursive: true);
    await File(outPath).writeAsBytes(file.content as List<int>);
  }

  // Multi-dex under base/dex/.
  for (final dex in dexFiles) {
    final src = File(dex);
    if (!await src.exists()) continue;
    final name = p.basename(dex);
    final destName =
        (name == 'classes.dex' || RegExp(r'^classes\d+\.dex$').hasMatch(name))
        ? name
        : 'classes.dex';
    final dest = p.join(baseDir, 'dex', destName);
    await File(dest).parent.create(recursive: true);
    await src.copy(dest);
  }

  if (flutterAssetsDir != null) {
    final srcDir = Directory(flutterAssetsDir);
    if (await srcDir.exists()) {
      final dest = Directory(p.join(baseDir, 'assets', 'flutter_assets'));
      await copyDirectoryTree(srcDir, dest);
    }
  }

  Future<void> stageNative(Map<String, String> byAbi, String soName) async {
    for (final entry in byAbi.entries) {
      final abi = normalizeBundleAbi(entry.key);
      final src = File(entry.value);
      if (!await src.exists()) continue;
      final dest = p.join(baseDir, 'lib', abi, soName);
      await File(dest).parent.create(recursive: true);
      await src.copy(dest);
    }
  }

  await stageNative(libflutterByAbi, 'libflutter.so');
  await stageNative(libappByAbi, 'libapp.so');

  for (final entry in extraNativeByAbi.entries) {
    final abi = normalizeBundleAbi(entry.key);
    for (final so in entry.value) {
      final src = File(so);
      if (!await src.exists()) continue;
      final dest = p.join(baseDir, 'lib', abi, p.basename(so));
      await File(dest).parent.create(recursive: true);
      await src.copy(dest);
    }
  }
}

/// Zip a bundle root ([bundleRoot] containing `base/`) into [aabPath].
Future<void> zipBundle(String bundleRoot, String aabPath) async {
  final archive = Archive();
  final root = Directory(bundleRoot);
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: bundleRoot).replaceAll(r'\', '/');
    final data = await entity.readAsBytes();
    archive.addFile(ArchiveFile(rel, data.length, data));
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw StateError('Failed to encode AAB zip from $bundleRoot');
  }
  await File(aabPath).parent.create(recursive: true);
  await File(aabPath).writeAsBytes(encoded, flush: true);
}

/// Sign an `.aab` with v1 JAR signing via jarsigner.
///
/// Returns the signed output path. [jarsignerPath] defaults to `jarsigner`
/// on PATH; oka resolves it next to javac when possible.
Future<String> signAab({
  required String unsignedAabPath,
  required String keystorePath,
  required String keyAlias,
  required String storePass,
  required String signedAabPath,
  String? jarsignerPath,
}) async {
  final tool = jarsignerPath ?? 'jarsigner';
  final result = await Process.run(tool, [
    '-keystore',
    keystorePath,
    '-storepass',
    storePass,
    '-signedjar',
    signedAabPath,
    unsignedAabPath,
    keyAlias,
  ]);
  if (result.exitCode != 0) {
    throw Exception('jarsigner failed: ${result.stderr}\n${result.stdout}');
  }
  return signedAabPath;
}

/// Describes files that must appear in a complete Flutter AAB `base/` module.
class AabLayoutSpec {
  final bool requireDex;
  final bool requireFlutterAssets;
  final bool requireProtoResources;
  final List<String> abis;
  final bool requireLibapp;

  const AabLayoutSpec({
    this.requireDex = true,
    this.requireFlutterAssets = true,
    this.requireProtoResources = true,
    this.abis = const ['arm64-v8a'],
    this.requireLibapp = false,
  });
}

/// Result of validating an AAB layout.
class AabLayoutValidation {
  final bool ok;
  final List<String> missing;
  final List<String> present;

  const AabLayoutValidation({
    required this.ok,
    required this.missing,
    required this.present,
  });
}

/// Validate paths already listed from an `.aab` zip (module-relative).
AabLayoutValidation validateAabPathSet(
  Iterable<String> paths, {
  AabLayoutSpec spec = const AabLayoutSpec(),
}) {
  final normalized = paths.map((e) => e.replaceAll(r'\', '/')).toSet().toList();
  final missing = <String>[];
  final present = <String>[];

  void check(String label, bool Function() ok) {
    if (ok()) {
      present.add(label);
    } else {
      missing.add(label);
    }
  }

  bool has(String entry) => normalized.contains('base/$entry');

  if (spec.requireProtoResources) {
    check('base/AndroidManifest.xml', () => has('AndroidManifest.xml'));
    check('base/resources.pb', () => has('resources.pb'));
  }
  if (spec.requireDex) {
    check(
      'base/dex/classes.dex',
      () =>
          has('dex/classes.dex') ||
          normalized.any(
            (e) => RegExp(r'^base/dex/classes\d*\.dex$').hasMatch(e),
          ),
    );
  }
  if (spec.requireFlutterAssets) {
    check(
      'base/assets/flutter_assets/',
      () => normalized.any((e) => e.startsWith('base/assets/flutter_assets')),
    );
  }
  for (final abi in spec.abis.map(normalizeBundleAbi)) {
    final so = 'base/lib/$abi/libflutter.so';
    check(so, () => normalized.contains(so));
    if (spec.requireLibapp) {
      check(
        'base/lib/$abi/libapp.so',
        () => normalized.contains('base/lib/$abi/libapp.so'),
      );
    }
  }

  return AabLayoutValidation(
    ok: missing.isEmpty,
    missing: missing,
    present: present,
  );
}

/// Read entry names from an `.aab` zip.
Future<List<String>> listAabEntries(String aabPath) async {
  final bytes = await File(aabPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  return archive
      .where((f) => f.isFile)
      .map((f) => f.name.replaceAll(r'\', '/'))
      .toList();
}

/// ABI normalization shared with the APK path (delegates to the same rules).
String normalizeBundleAbi(String abi) {
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

Future<void> copyDirectoryTree(Directory source, Directory dest) async {
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
