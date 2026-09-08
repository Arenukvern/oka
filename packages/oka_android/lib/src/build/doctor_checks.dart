/// Android doctor checks (ADR-0015: check mechanics live behind the CLI
/// verb — `oka doctor` formats whatever these return; the `[Toolchain
/// Policy]` block semantics are unchanged, ADR-0013).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'sdk_locator.dart' show SdkLocator;
import 'toolchain.dart';

/// Outcome of one Android toolchain doctor check.
class AndroidToolCheck {

  const AndroidToolCheck({
    required this.tool,
    required this.found,
    this.path,
    this.error,
  });
  final String tool;
  final bool found;
  /// Resolved tool path when [found].
  final String? path;
  /// The resolution failure when not found.
  final Object? error;
}

/// Result of the Android SDK section of `oka doctor`.
class AndroidSdkDoctorReport {

  const AndroidSdkDoctorReport({
    this.sdkPath,
    this.sdkError,
    this.toolChecks = const [],
    this.r8Path,
  });
  /// Android SDK root when found, else null.
  final String? sdkPath;
  /// The resolution failure when [sdkPath] is null.
  final Object? sdkError;
  /// Packaging tool checks in the doctor's display order. Empty when the
  /// SDK root itself was not found.
  final List<AndroidToolCheck> toolChecks;
  /// R8 path when found (optional tool), else null.
  final String? r8Path;

  bool get sdkFound => sdkPath != null;
}

/// Runs the Android SDK doctor checks (ADR-0013 toolchain policy semantics:
/// same resolution, same order, results as data).
///
/// [toolchain] is injectable (the doctor command passes its [SdkLocator]).
Future<AndroidSdkDoctorReport> androidSdkDoctorChecks({
  final ResolvedToolchain? toolchain,
}) async {
  final tc = toolchain ?? SdkLocator();

  String? sdkPath;
  Object? sdkError;
  try {
    sdkPath = await tc.findAndroidSdk();
  } catch (e) {
    sdkError = e;
  }
  if (sdkPath == null) {
    return AndroidSdkDoctorReport(sdkError: sdkError);
  }

  Future<AndroidToolCheck> check(
    final String name,
    final Future<String> Function() find,
  ) async {
    try {
      return AndroidToolCheck(tool: name, found: true, path: await find());
    } catch (e) {
      return AndroidToolCheck(tool: name, found: false, error: e);
    }
  }

  final checks = [
    await check('aapt2', tc.findAapt2),
    await check('d8', tc.findD8),
    await check('zipalign', tc.findZipalign),
    await check('apksigner', tc.findApksigner),
    await check('adb', tc.findAdb),
  ];

  String? r8Path;
  try {
    r8Path = await tc.findR8();
  } catch (_) {
    r8Path = null;
  }

  return AndroidSdkDoctorReport(
    sdkPath: sdkPath,
    toolChecks: checks,
    r8Path: r8Path,
  );
}

/// Default oka tools dir (`~/.oka/tools`).
Directory defaultOkaToolsDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return Directory(p.join(home, '.oka', 'tools'));
}

/// True when a bundletool jar/wrapper sits under the oka tools dir
/// (`~/.oka/tools`) — the doctor's presence signal for the AAB verification
/// dependency (ADR-0004). [toolsDir] is injectable for tests.
Future<bool> bundletoolAvailableInOkaTools({final Directory? toolsDir}) async {
  final dir = toolsDir ?? defaultOkaToolsDir();
  if (!dir.existsSync()) return false;
  return dir.listSync().any(
        (e) => p.basename(e.path).startsWith('bundletool'),
      );
}

/// Build-Health lines for the bundletool verification dependency, formatted
/// exactly as `oka doctor` prints them (ADR-0015: the strings live with the
/// mechanism they describe). [toolsDir] is injectable for tests.
Future<List<String>> bundletoolHealthLines({final Directory? toolsDir}) async {
  final installed = await bundletoolAvailableInOkaTools(toolsDir: toolsDir);
  const missingLine =
      '  ℹ️  bundletool not installed (only needed for --verify-aab) —'
      ' "oka get bundletool"';
  return installed
      ? const ['  ✅ bundletool: available for AAB verification']
      : const [missingLine];
}
