import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/apk_layout.dart';
import '../build/toolchain.dart';
import '../compilation/process_runner.dart';
import '../signing/android_signing.dart';
import '../signing_config.dart';

Future<String> packageAndSign({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required List<String> dexFiles,
  required String flutterAssetsDir,
  required Map<String, String> libflutterByAbi,
  required Map<String, String> libappByAbi,
  Map<String, List<String>> extraNativeByAbi = const {},
  SigningConfig? signing,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  final staging = p.join(ctx.buildDir, 'staging');
  final resources = p.join(ctx.buildDir, 'resources.ap_');
  await stageApkLayout(
    stagingDir: staging,
    dexFiles: dexFiles,
    flutterAssetsDir: flutterAssetsDir,
    libflutterByAbi: libflutterByAbi,
    libappByAbi: libappByAbi,
    resourcesApk: await File(resources).exists() ? resources : null,
  );
  for (final entry in extraNativeByAbi.entries) {
    final abi = normalizeAbi(entry.key);
    for (final library in entry.value) {
      final destination = File(
        p.join(staging, 'lib', abi, p.basename(library)),
      );
      await destination.parent.create(recursive: true);
      await File(library).copy(destination.path);
    }
  }
  final unsigned = p.join(ctx.buildDir, 'app-${ctx.mode.name}-unsigned.apk');
  await zipStagingToApk(staging, unsigned);
  final aligned = p.join(ctx.buildDir, 'app-${ctx.mode.name}-aligned.apk');
  final signed = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');
  final result = await processRunner(await toolchain.findZipalign(), [
    '-f',
    '-p',
    '4',
    unsigned,
    aligned,
  ]);
  if (result.exitCode != 0) {
    throw Exception('zipalign failed: ${result.stderr}');
  }
  await signApk(
    ctx: ctx,
    apksigner: await toolchain.findApksigner(),
    alignedApk: aligned,
    signedApk: signed,
    signing: signing,
    processRunner: processRunner,
  );
  return signed;
}
