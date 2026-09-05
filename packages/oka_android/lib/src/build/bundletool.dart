import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// bundletool helpers for AAB verification (ADR-0004).
///
/// An `.aab` cannot be installed on a device directly. The verification loop
/// is: `bundletool build-apks --mode=universal` → extract/install the
/// universal APK. bundletool is a *verification* dependency only — oka's
/// build path never requires it.

/// Default install location for bundletool.jar under the oka cache.
String defaultBundletoolJarPath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return p.join(home, '.oka', 'tools', 'bundletool.jar');
}

/// Latest bundletool release download URL (GitHub releases).
const kBundletoolDownloadUrl =
    'https://github.com/google/bundletool/releases/download/1.17.0/bundletool-all-1.17.0.jar';

/// Locate a usable bundletool jar: explicit path, OKA env var, oka tools dir,
/// then PATH lookup for a `bundletool` wrapper.
Future<String?> findBundletool({String? explicitPath}) async {
  final candidates = [
    if (explicitPath != null && explicitPath.isNotEmpty) explicitPath,
    Platform.environment['OKA_BUNDLETOOL_JAR'],
    defaultBundletoolJarPath(),
  ].whereType<String>().toList();
  for (final c in candidates) {
    if (await File(c).exists()) return c;
  }
  try {
    final r = await Process.run('which', ['bundletool']);
    if (r.exitCode == 0) {
      final wrapper = (r.stdout as String).trim();
      if (wrapper.isNotEmpty) return wrapper;
    }
  } catch (_) {}
  return null;
}

/// Download bundletool into the oka tools directory.
///
/// Requires `curl` on PATH (same bootstrap pattern as cmdline-tools).
Future<String> downloadBundletool({
  String? destPath,
  bool verbose = false,
}) async {
  final dest = destPath ?? defaultBundletoolJarPath();
  await File(dest).parent.create(recursive: true);
  final r = await Process.run('curl', [
    '-L',
    '-f',
    '-o',
    dest,
    kBundletoolDownloadUrl,
  ]);
  if (r.exitCode != 0 || !await File(dest).exists()) {
    throw Exception(
      'Failed to download bundletool from $kBundletoolDownloadUrl: '
      '${r.stderr}',
    );
  }
  if (verbose) print('📥 bundletool downloaded → $dest');
  return dest;
}

/// Result of a bundletool verification run.
class BundletoolVerifyResult {
  final bool ok;
  final String? error;
  final String apksPath;

  const BundletoolVerifyResult({
    required this.ok,
    required this.apksPath,
    this.error,
  });
}

/// Verify an `.aab` by building universal APKs with bundletool.
///
/// This exercises the same parsing/generation path Google Play uses, so a
/// structurally invalid bundle fails here before upload.
Future<BundletoolVerifyResult> verifyAabWithBundletool({
  required String aabPath,
  required String outputApksPath,
  required String keystorePath,
  required String keyAlias,
  required String keyPass,
  String? bundletoolPath,
  bool verbose = false,
}) async {
  final tool = await findBundletool(explicitPath: bundletoolPath);
  if (tool == null) {
    return BundletoolVerifyResult(
      ok: false,
      apksPath: outputApksPath,
      error:
          'bundletool not found. Install with: oka get bundletool\n'
          '(or set OKA_BUNDLETOOL_JAR / brew install bundletool)',
    );
  }

  final args = tool.endsWith('.jar')
      ? <String>['java', '-jar', tool, 'build-apks']
      : <String>[tool, 'build-apks'];
  args.addAll([
    '--bundle=$aabPath',
    '--output=$outputApksPath',
    '--mode=universal',
    '--ks=$keystorePath',
    '--ks-key-alias=$keyAlias',
    '--ks-pass=pass:$keyPass',
    '--overwrite',
  ]);
  if (verbose) print('   Running: ${args.join(' ')}');

  final result = await Process.run(args.first, args.sublist(1));
  if (result.exitCode != 0) {
    return BundletoolVerifyResult(
      ok: false,
      apksPath: outputApksPath,
      error:
          'bundletool build-apks failed (exit ${result.exitCode}):\n'
          '${result.stderr}\n${result.stdout}',
    );
  }
  if (!await File(outputApksPath).exists()) {
    return BundletoolVerifyResult(
      ok: false,
      apksPath: outputApksPath,
      error: 'bundletool reported success but no .apks at $outputApksPath',
    );
  }
  return BundletoolVerifyResult(ok: true, apksPath: outputApksPath);
}

/// Extract the universal APK from a `.apks` archive (it is a zip with
/// `splits/universal.apk`).
Future<String> extractUniversalApk(String apksPath, String destApkPath) async {
  final bytes = await File(apksPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  ArchiveFile? universal;
  for (final f in archive) {
    if (f.isFile &&
        (f.name == 'splits/universal.apk' ||
            f.name.endsWith('universal.apk'))) {
      universal = f;
      break;
    }
  }
  if (universal == null) {
    throw Exception('No splits/universal.apk found inside $apksPath');
  }
  await File(destApkPath).parent.create(recursive: true);
  await File(destApkPath).writeAsBytes(universal.content as List<int>);
  return destApkPath;
}
