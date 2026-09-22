import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'apk_layout.dart' show listRelativePaths;

/// App Bundle layout helpers (ADR-0004).
///
/// An `.aab` is a zip per the App Bundle format spec:
///
/// ```
/// BundleConfig.pb               (bundle metadata, minimal protobuf)
/// base/manifest/AndroidManifest.xml   (protobuf, from aapt2 --proto-format)
/// base/resources.pb
/// base/res/**                   (compiled resources)
/// base/dex/classes*.dex
/// base/lib/<abi>/*.so
/// base/assets/flutter_assets/**
/// ```
///
/// Note the manifest lives under `base/manifest/` — unlike APKs. Bundles are
/// signed with **v1 JAR signing** (jarsigner); apksigner does not sign bundles.

/// Minimal `BundleConfig.pb`: a BundleConfig protobuf message with only the
/// compression (unspecified → default) and optimization fields unset, which
/// bundletool accepts as valid.
/// Minimal `BundleConfig.pb`: BundleConfig { bundletool { version {
/// major: 1 minor: 17 revision: 0 } } } — hand-encoded protobuf.
///
/// bundletool ≥1.x requires a parseable version in BundleConfig when
/// validating/building (empty messages are rejected with
/// `Version must match the format '<major>.<minor>.<revision>'`).
///
/// Wire format:
/// - BundleConfig.bundletool (field 1, length-delimited → 0x0A)
/// - Bundletool.version (field 1, length-delimited → 0x0A)
/// - Version.major/minor/revision (fields 1..3, varints)
/// Minimal `BundleConfig.pb` — byte-identical in structure to what
/// `bundletool build-bundle` emits:
///
/// ```text
/// BundleConfig {
///   bundletool {           // field 1, length-delimited (0x0A)
///     version: "1.17.0"    // field 2, STRING (0x12) — not a message!
///   }
/// }
/// ```
///
/// bundletool ≥1.x rejects a BundleConfig without a parseable version
/// (`Version must match the format '<major>.<minor>.<revision>'`).
/// Keep in sync with the bundletool version in `oka get bundletool`.
List<int> minimalBundleConfigPb() {
  const version = '1.17.0';
  final versionBytes = version.codeUnits;
  // field 2 (0x12), len, then ASCII bytes
  final bundletool = <int>[0x12, versionBytes.length, ...versionBytes];
  // field 1 (0x0A), len, then bundletool message
  return <int>[0x0A, bundletool.length, ...bundletool];
}

/// Stage an AAB `base/` module directory.
///
/// - [protoResourcesAp] — output of `aapt2 link --proto-format`; its entries
///   (AndroidManifest.xml, resources.pb, res/**) explode into `base/`.
/// - [dexFiles] — copied to `base/dex/` preserving classesN.dex names.
/// - [flutterAssetsDir] → `base/assets/flutter_assets/`.
/// - [libflutterByAbi] / [libappByAbi] / [extraNativeByAbi] → `base/lib/<abi>/`.
Future<void> stageAabBaseModule({
  required final String baseDir,
  required final String protoResourcesAp,
  final List<String> dexFiles = const [],
  final String? flutterAssetsDir,
  final Map<String, String> libflutterByAbi = const {},
  final Map<String, String> libappByAbi = const {},
  final Map<String, List<String>> extraNativeByAbi = const {},
}) async {
  final root = Directory(baseDir);
  if (await root.exists()) {
    await root.delete(recursive: true);
  }
  await root.create(recursive: true);

  // Proto-format resources archive: AndroidManifest.xml must land under
  // base/manifest/ per the App Bundle spec; resources.pb and res/** stay at
  // base/ root.
  final bytes = await File(protoResourcesAp).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    if (!file.isFile) continue;
    var name = file.name.replaceAll(r'\', '/');
    if (name == 'AndroidManifest.xml') {
      name = 'manifest/AndroidManifest.xml';
    }
    final outPath = p.join(baseDir, name);
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

  Future<void> stageNative(
    final Map<String, String> byAbi,
    final String soName,
  ) async {
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
Future<void> zipBundle(final String bundleRoot, final String aabPath) async {
  final archive = Archive();
  // Deterministic artifact bytes (ADR-0007): sorted entry order.
  final entries = await listRelativePaths(Directory(bundleRoot));
  final sorted = entries.toList()..sort();
  for (final rel in sorted) {
    final data = await File(p.join(bundleRoot, rel)).readAsBytes();
    archive.addFile(ArchiveFile(rel, data.length, data));
  }
  final encoded = ZipEncoder().encodeBytes(archive);
  await File(aabPath).parent.create(recursive: true);
  await File(aabPath).writeAsBytes(encoded, flush: true);
}

/// Sign an `.aab` with v1 JAR signing via jarsigner.
///
/// Returns the signed output path. [jarsignerPath] defaults to `jarsigner`
/// on PATH; oka resolves it next to javac when possible.
Future<String> signAab({
  required final String unsignedAabPath,
  required final String keystorePath,
  required final String keyAlias,
  required final String storePass,
  required final String signedAabPath,
  final String? jarsignerPath,
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
  const AabLayoutSpec({
    this.requireDex = true,
    this.requireFlutterAssets = true,
    this.requireProtoResources = true,
    this.requireBundleConfig = true,
    this.abis = const ['arm64-v8a'],
    this.requireLibapp = false,
    this.requireSignature = false,
  });
  final bool requireDex;
  final bool requireFlutterAssets;
  final bool requireProtoResources;
  final bool requireBundleConfig;
  final List<String> abis;
  final bool requireLibapp;

  /// Require the v1 JAR signature written by `jarsigner`.
  ///
  /// This is false for callers validating an unsigned staging bundle. The
  /// packaged artifact validation step enables it.
  final bool requireSignature;
}

/// Result of validating an AAB layout.
class AabLayoutValidation {
  const AabLayoutValidation({
    required this.ok,
    required this.missing,
    required this.present,
  });
  final bool ok;
  final List<String> missing;
  final List<String> present;
}

/// Detailed checks on the contents of an AAB, beyond its expected file names.
///
/// These checks deliberately do not attempt to decode every protobuf field
/// (that would couple oka to bundletool's generated classes). They do verify
/// the invariants which can otherwise result in a bundle that zips
/// successfully but cannot be consumed by Android tooling.
class AabContentValidation {
  const AabContentValidation({
    required this.ok,
    required this.errors,
    required this.warnings,
  });

  final bool ok;
  final List<String> errors;
  final List<String> warnings;
}

/// Validate paths already listed from an `.aab` zip (module-relative).
AabLayoutValidation validateAabPathSet(
  final Iterable<String> paths, {
  final AabLayoutSpec spec = const AabLayoutSpec(),
}) {
  final normalized = paths
      .map((final e) => e.replaceAll(r'\', '/'))
      .toSet()
      .toList();
  final missing = <String>[];
  final present = <String>[];

  void check(final String label, final bool Function() ok) {
    if (ok()) {
      present.add(label);
    } else {
      missing.add(label);
    }
  }

  bool has(final String entry) => normalized.contains('base/$entry');

  if (spec.requireBundleConfig) {
    check('BundleConfig.pb', () => normalized.contains('BundleConfig.pb'));
  }
  if (spec.requireProtoResources) {
    // Manifest lives under base/manifest/ per the App Bundle format spec.
    check(
      'base/manifest/AndroidManifest.xml',
      () => has('manifest/AndroidManifest.xml'),
    );
    check('base/resources.pb', () => has('resources.pb'));
  }
  if (spec.requireDex) {
    check(
      'base/dex/classes.dex',
      () =>
          has('dex/classes.dex') ||
          normalized.any(
            (final e) => RegExp(r'^base/dex/classes\d*\.dex$').hasMatch(e),
          ),
    );
  }
  if (spec.requireFlutterAssets) {
    check(
      'base/assets/flutter_assets/',
      () => normalized.any(
        (final e) => e.startsWith('base/assets/flutter_assets'),
      ),
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
  if (spec.requireSignature) {
    check(
      'META-INF/MANIFEST.MF',
      () => normalized.contains('META-INF/MANIFEST.MF'),
    );
    check(
      'META-INF/*.SF',
      () => normalized.any(
        (final e) => RegExp(r'^META-INF/[^/]+\.SF$').hasMatch(e),
      ),
    );
    check(
      'META-INF/*.(RSA|DSA|EC)',
      () => normalized.any(
        (final e) => RegExp(r'^META-INF/[^/]+\.(RSA|DSA|EC)$').hasMatch(e),
      ),
    );
  }

  return AabLayoutValidation(
    ok: missing.isEmpty,
    missing: missing,
    present: present,
  );
}

/// Validate an AAB archive, including manifest, DEX, native ABI, resource,
/// duplicate-entry, and (optionally) v1 signature invariants.
Future<AabContentValidation> validateAabFile(
  final String aabPath, {
  final AabLayoutSpec spec = const AabLayoutSpec(),
}) async {
  final errors = <String>[];
  final warnings = <String>[];
  final archive = ZipDecoder().decodeBytes(await File(aabPath).readAsBytes());
  final files = archive.where((final f) => f.isFile).toList();
  final names = files.map((final f) => f.name.replaceAll(r'\', '/')).toList();
  final counts = <String, int>{};
  for (final name in names) {
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final duplicates = counts.entries
      .where((final e) => e.value > 1)
      .map((final e) => '${e.key} (${e.value} entries)')
      .toList();
  if (duplicates.isNotEmpty) {
    errors.add('duplicate ZIP entries: ${duplicates.join(', ')}');
  }

  final layout = validateAabPathSet(names, spec: spec);
  errors.addAll(layout.missing.map((final e) => 'missing $e'));
  ArchiveFile? entry(final String name) {
    for (final file in files) {
      if (file.name.replaceAll(r'\', '/') == name) return file;
    }
    return null;
  }

  List<int> bytes(final String name) =>
      entry(name)?.content as List<int>? ?? const [];

  final manifest = bytes('base/manifest/AndroidManifest.xml');
  if (spec.requireProtoResources && manifest.isEmpty) {
    errors.add('base/manifest/AndroidManifest.xml is empty');
  }
  // Proto manifests contain the package value as a length-delimited UTF-8
  // string. Requiring at least one printable string catches an accidentally
  // copied text/empty manifest without pretending to be a protobuf parser.
  if (manifest.isNotEmpty &&
      !manifest.skip(1).any((final b) => b >= 0x20 && b <= 0x7e)) {
    errors.add(
      'base/manifest/AndroidManifest.xml has no readable protobuf data',
    );
  }
  final resources = bytes('base/resources.pb');
  if (spec.requireProtoResources && resources.isEmpty) {
    errors.add('base/resources.pb is empty');
  }

  final dexNames = names
      .where((final n) => RegExp(r'^base/dex/classes\d*\.dex$').hasMatch(n))
      .toList();
  for (final dexName in dexNames) {
    final dex = bytes(dexName);
    if (dex.length < 8 ||
        dex[0] != 0x64 ||
        dex[1] != 0x65 ||
        dex[2] != 0x78 ||
        dex[3] != 0x0a) {
      errors.add('$dexName is not a DEX file');
    }
  }
  if (dexNames.contains('base/dex/classes.dex')) {
    for (var i = 2; i <= dexNames.length; i++) {
      if (!dexNames.contains('base/dex/classes$i.dex')) {
        errors.add('DEX files are not contiguous: missing classes$i.dex');
      }
    }
  }

  for (final name in names) {
    final match = RegExp(r'^base/lib/([^/]+)/([^/]+\.so)$').firstMatch(name);
    if (match == null) continue;
    final abi = match.group(1)!;
    if (!spec.abis.map(normalizeBundleAbi).contains(abi)) {
      warnings.add('native library uses ABI not requested by config: $abi');
    }
  }
  if (spec.requireSignature) {
    final hasManifest = names.contains('META-INF/MANIFEST.MF');
    final hasSf = names.any(
      (final n) => RegExp(r'^META-INF/[^/]+\.SF$').hasMatch(n),
    );
    final hasBlock = names.any(
      (final n) => RegExp(r'^META-INF/[^/]+\.(RSA|DSA|EC)$').hasMatch(n),
    );
    if (!hasManifest || !hasSf || !hasBlock) {
      errors.add(
        'AAB is not v1 signed (expected META-INF/MANIFEST.MF, .SF and '
        '.RSA/.DSA/.EC entries)',
      );
    }
  }
  return AabContentValidation(
    ok: errors.isEmpty,
    errors: errors,
    warnings: warnings,
  );
}

/// Read entry names from an `.aab` zip.
Future<List<String>> listAabEntries(final String aabPath) async {
  final bytes = await File(aabPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  return archive
      .where((final f) => f.isFile)
      .map((final f) => f.name.replaceAll(r'\', '/'))
      .toList();
}

/// ABI normalization shared with the APK path (delegates to the same rules).
String normalizeBundleAbi(final String abi) {
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

Future<void> copyDirectoryTree(
  final Directory source,
  final Directory dest,
) async {
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
