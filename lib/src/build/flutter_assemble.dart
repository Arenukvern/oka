import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/build_context.dart';
import 'apk_layout.dart';

/// Build mode string for flutter assemble defines.
String assembleBuildMode(BuildMode mode) {
  switch (mode) {
    case BuildMode.release:
      return 'release';
    case BuildMode.profile:
      return 'profile';
    case BuildMode.debug:
      return 'debug';
  }
}

/// Flutter assemble target name for Android application assets (debug/profile).
///
/// Release AOT uses [androidAotBundleTarget] for native `libapp.so` bundles.
String androidApplicationTarget(BuildMode mode) {
  switch (mode) {
    case BuildMode.release:
      // Release still needs asset bundle; AOT is a separate target.
      return 'release_android_application';
    case BuildMode.profile:
      return 'profile_android_application';
    case BuildMode.debug:
      return 'debug_android_application';
  }
}

/// AOT bundle target for a given ABI (produces app.so / libapp.so layouts).
String androidAotBundleTarget(String abi) {
  final n = normalizeAbi(abi);
  switch (n) {
    case 'arm64-v8a':
      return 'android_aot_bundle_release_android-arm64';
    case 'armeabi-v7a':
      return 'android_aot_bundle_release_android-arm';
    case 'x86_64':
      return 'android_aot_bundle_release_android-x64';
    default:
      return 'android_aot_bundle_release_android-arm64';
  }
}

/// Target platform define value for Flutter tools.
String targetPlatformForAbi(String abi) {
  final n = normalizeAbi(abi);
  switch (n) {
    case 'arm64-v8a':
      return 'android-arm64';
    case 'armeabi-v7a':
      return 'android-arm';
    case 'x86_64':
      return 'android-x64';
    case 'x86':
      return 'android-x86';
    default:
      return 'android-arm64';
  }
}

/// Pure command construction for `flutter assemble` (asset/kernel pipeline).
///
/// Returns argv after the `flutter` executable (i.e. starts with `assemble`).
List<String> buildFlutterAssembleArgs({
  required String outputDir,
  required String targetFile,
  required BuildMode mode,
  required String targetPlatform,
  List<String> extraArgs = const [],
  bool trackWidgetCreation = true,
}) {
  final buildMode = assembleBuildMode(mode);
  final target = androidApplicationTarget(mode);

  final args = <String>[
    'assemble',
    '--no-version-check',
    '--output',
    outputDir,
    '-dTargetFile=$targetFile',
    '-dTargetPlatform=$targetPlatform',
    '-dBuildMode=$buildMode',
    if (mode == BuildMode.debug && trackWidgetCreation)
      '-dTrackWidgetCreation=true',
    target,
    ...extraArgs,
  ];
  return args;
}

/// Pure command construction for release AOT bundle assemble.
List<String> buildFlutterAotAssembleArgs({
  required String outputDir,
  required String targetFile,
  required String abi,
  List<String> extraArgs = const [],
}) {
  final platform = targetPlatformForAbi(abi);
  final target = androidAotBundleTarget(abi);
  return <String>[
    'assemble',
    '--no-version-check',
    '--output',
    outputDir,
    '-dTargetFile=$targetFile',
    '-dTargetPlatform=$platform',
    '-dBuildMode=release',
    target,
    ...extraArgs,
  ];
}

/// Result of a Flutter assemble invocation.
class FlutterAssembleResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final String outputDir;
  final String? flutterAssetsDir;

  const FlutterAssembleResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.outputDir,
    this.flutterAssetsDir,
  });

  bool get success => exitCode == 0;
}

/// Locates `flutter_assets` under an assemble output directory.
Future<String?> findFlutterAssetsDir(String assembleOutput) async {
  final candidates = [
    p.join(assembleOutput, 'flutter_assets'),
    p.join(assembleOutput, 'assets', 'flutter_assets'),
  ];
  for (final c in candidates) {
    if (await Directory(c).exists()) {
      return c;
    }
  }
  // Search one level deep.
  final root = Directory(assembleOutput);
  if (!await root.exists()) return null;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is Directory && p.basename(entity.path) == 'flutter_assets') {
      return entity.path;
    }
  }
  return null;
}

/// Locates `app.so` / `libapp.so` under an AOT assemble output.
Future<String?> findLibappSo(String aotOutput) async {
  final root = Directory(aotOutput);
  if (!await root.exists()) return null;
  final preferred = [
    p.join(aotOutput, 'app.so'),
    p.join(aotOutput, 'libapp.so'),
  ];
  for (final c in preferred) {
    if (await File(c).exists()) return c;
  }
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final name = p.basename(entity.path);
      if (name == 'app.so' || name == 'libapp.so') {
        return entity.path;
      }
    }
  }
  return null;
}

/// Runs `flutter assemble` for the Android application target.
class FlutterAssembler {
  final bool verbose;
  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) runProcess;

  FlutterAssembler({
    this.verbose = false,
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    })? runProcess,
  }) : runProcess = runProcess ?? Process.run;

  Future<FlutterAssembleResult> assembleApplication({
    required String projectPath,
    required String outputDir,
    required String entrypoint,
    required BuildMode mode,
    required String primaryAbi,
    List<String> extraArgs = const [],
  }) async {
    await Directory(outputDir).create(recursive: true);
    final platform = targetPlatformForAbi(primaryAbi);
    final args = buildFlutterAssembleArgs(
      outputDir: outputDir,
      targetFile: entrypoint,
      mode: mode,
      targetPlatform: platform,
      extraArgs: extraArgs,
    );

    if (verbose) {
      print('   Running: flutter ${args.join(' ')}');
    }

    final result = await runProcess(
      'flutter',
      args,
      workingDirectory: projectPath,
    );

    final assets = await findFlutterAssetsDir(outputDir);
    return FlutterAssembleResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
      outputDir: outputDir,
      flutterAssetsDir: assets,
    );
  }

  Future<FlutterAssembleResult> assembleAot({
    required String projectPath,
    required String outputDir,
    required String entrypoint,
    required String abi,
    List<String> extraArgs = const [],
  }) async {
    await Directory(outputDir).create(recursive: true);
    final args = buildFlutterAotAssembleArgs(
      outputDir: outputDir,
      targetFile: entrypoint,
      abi: abi,
      extraArgs: extraArgs,
    );

    if (verbose) {
      print('   Running: flutter ${args.join(' ')}');
    }

    final result = await runProcess(
      'flutter',
      args,
      workingDirectory: projectPath,
    );

    return FlutterAssembleResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
      outputDir: outputDir,
    );
  }
}

/// Reads Flutter engine revision from `flutter --version --machine`.
Future<String?> readFlutterEngineRevision({
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final runner = runProcess ?? (e, a) => Process.run(e, a);
  try {
    final result = await runner('flutter', ['--version', '--machine']);
    if (result.exitCode != 0) return null;
    final json = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    final rev = json['engineRevision'] as String?;
    return rev;
  } catch (_) {
    return null;
  }
}
