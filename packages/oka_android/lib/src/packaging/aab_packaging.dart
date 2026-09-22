import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/aab_layout.dart';
import '../build/toolchain.dart';
import '../compilation/process_runner.dart';
import '../signing/android_signing.dart';
import '../signing_config.dart';

Future<String> packageAndSignAab({
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
  final base = p.join(ctx.buildDir, 'aab', 'base');
  await stageAabBaseModule(
    baseDir: base,
    protoResourcesAp: p.join(ctx.buildDir, 'resources_proto.ap_'),
    dexFiles: dexFiles,
    flutterAssetsDir: flutterAssetsDir,
    libflutterByAbi: libflutterByAbi,
    libappByAbi: libappByAbi,
    extraNativeByAbi: extraNativeByAbi,
  );
  final bundleRoot = p.dirname(base);
  final bundleDirectory = Directory(bundleRoot);
  if (await bundleDirectory.exists()) {
    await for (final entry in bundleDirectory.list()) {
      if (p.basename(entry.path) != 'base') await entry.delete(recursive: true);
    }
  }
  await File(
    p.join(bundleRoot, 'BundleConfig.pb'),
  ).writeAsBytes(minimalBundleConfigPb(), flush: true);
  final unsigned = p.join(bundleRoot, 'app-${ctx.mode.name}-unsigned.aab');
  await zipBundle(bundleRoot, unsigned);
  final signed = p.join(bundleRoot, 'app-${ctx.mode.name}.aab');
  await signBundle(
    ctx: ctx,
    toolchain: toolchain,
    unsignedBundle: unsigned,
    signedBundle: signed,
    signing: signing,
    processRunner: processRunner,
  );
  return signed;
}
