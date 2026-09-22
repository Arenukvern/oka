import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../dev/adb_tool.dart';
import '../pipeline/toolchain.dart' show debugKeystore;
import 'bundletool.dart';

/// Android implementation of the shared delivery verification contract.
class AndroidDeliveryVerifier implements DeliveryVerifier {
  const AndroidDeliveryVerifier();

  @override
  Future<DeliveryVerificationReport> verify({
    required String artifact,
    required String outputDirectory,
    DeliveryVerificationOptions options = const DeliveryVerificationOptions(),
    bool verbose = false,
  }) =>
      verifyAndroidDelivery(
        aabPath: artifact,
        outputDirectory: outputDirectory,
        deviceSpecPath: options.deviceSpecPath,
        bundletoolPath: options.toolPath,
        serial: options.deviceId,
        install: options.install,
        launch: options.launch,
        packageName: options.packageName,
        activity: options.activity,
        reportPath: options.reportPath,
        verbose: verbose,
      );
}

/// Runs the offline/online portions of release verification. The callback
/// seams make the report testable without Java, bundletool, adb, or a device.
Future<DeliveryVerificationReport> verifyAndroidDelivery({
  required String aabPath,
  required String outputDirectory,
  String? deviceSpecPath,
  String? bundletoolPath,
  String? serial,
  bool install = false,
  bool launch = false,
  String? packageName,
  String? activity,
  String? adbPath,
  String? keystorePath,
  bool verbose = false,
  String? reportPath,
  Future<String> Function()? keystore,
  Future<BundletoolCommandResult> Function(List<String> args)? runBundletool,
  Future<void> Function(List<String> apks)? installApks,
  Future<void> Function()? launchApp,
}) async {
  final file = File(aabPath);
  final bytes = await file.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final abis = <String>{};
  final entries = <String>[];
  for (final entry in archive) {
    entries.add(entry.name);
    final match = RegExp('(?:^|/)lib/([^/]+)/').firstMatch(entry.name);
    if (match != null) abis.add(match.group(1)!);
  }
  final gates = <String, bool>{'artifact_exists': file.existsSync()};
  final sha = sha256.convert(bytes).toString();
  final output = Directory(outputDirectory);
  await output.create(recursive: true);
  final tool = await findBundletool(explicitPath: bundletoolPath);
  Future<BundletoolCommandResult> run(final List<String> args) async {
    if (runBundletool != null) return runBundletool(args);
    if (tool == null) {
      return const BundletoolCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'bundletool not found',
      );
    }
    final command = tool.endsWith('.jar')
        ? ['java', '-jar', tool, ...args]
        : [tool, ...args];
    if (verbose) print('   Running: ${command.join(' ')}');
    final result = await Process.run(command.first, command.sublist(1));
    return BundletoolCommandResult(
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  final validate = await run(['validate', '--bundle=$aabPath']);
  gates['bundletool_validate'] = validate.exitCode == 0;
  String? spec = deviceSpecPath;
  if (spec == null && tool != null && (install || launch)) {
    spec = p.join(outputDirectory, 'device-spec.json');
    final result = await run(['get-device-spec', '--output=$spec']);
    gates['device_spec'] = result.exitCode == 0 && File(spec).existsSync();
  } else if (spec != null) {
    gates['device_spec'] = File(spec).existsSync();
  }

  List<String>? generated;
  if (spec != null && File(spec).existsSync()) {
    final apksPath = p.join(outputDirectory, 'device.apks');
    // An injected runner is commonly used for offline tests and does not
    // need a host Android SDK/debug keystore.
    final ks = keystorePath ??
        (runBundletool == null
            ? await (keystore ?? debugKeystore)()
            : '');
    final result = await run([
      'build-apks',
      '--bundle=$aabPath',
      '--output=$apksPath',
      '--device-spec=$spec',
      '--ks=$ks',
      '--ks-key-alias=androiddebugkey',
      '--ks-pass=pass:android',
      '--overwrite',
    ]);
    gates['device_specific_apks'] =
        result.exitCode == 0 && File(apksPath).existsSync();
    if (gates['device_specific_apks']!) {
      final decoded = ZipDecoder().decodeBytes(await File(apksPath).readAsBytes());
      generated = [];
      for (final entry in decoded) {
        if (!entry.isFile || !entry.name.endsWith('.apk')) continue;
        final destination = p.join(outputDirectory, p.basename(entry.name));
        await File(destination).writeAsBytes(entry.content as List<int>);
        generated.add(destination);
      }
      gates['apk_extracted'] = generated.isNotEmpty;
    }
  }
  final apkSizes = <String, int>{
    for (final apk in generated ?? <String>[]) apk: File(apk).lengthSync(),
  };
  var installAttempted = false;
  var launchAttempted = false;
  if (install && generated != null && generated.isNotEmpty) {
    installAttempted = true;
    try {
      if (installApks != null) {
        await installApks(generated);
      } else {
        final adb = AdbTool(adbPath: adbPath ?? 'adb', serial: serial);
        // install-multiple is intentionally kept in the device helper rather
        // than reimplementing adb invocation in the CLI.
        await adb.installMultiple(generated);
      }
      gates['install'] = true;
    } catch (_) {
      gates['install'] = false;
    }
  }
  if (launch) {
    launchAttempted = true;
    try {
      if (launchApp != null) {
        await launchApp();
      } else if (packageName != null && activity != null) {
        await AdbTool(adbPath: adbPath ?? 'adb', serial: serial)
            .launch(packageName, activity);
      } else {
        throw ArgumentError('packageName and activity are required for launch');
      }
      gates['launch'] = true;
    } catch (_) {
      gates['launch'] = false;
    }
  }
  final report = DeliveryVerificationReport(
    artifact: aabPath,
    artifactSha256: sha,
    artifactBytes: bytes.length,
    abis: (abis.toList()..sort()),
    gates: gates,
    deviceSpec: spec,
    generatedApks: generated,
    installAttempted: installAttempted,
    launchAttempted: launchAttempted,
    metadata: {'zip_entries': entries.length, 'apk_sizes': apkSizes},
  );
  if (reportPath != null) {
    final reportFile = File(reportPath);
    await reportFile.parent.create(recursive: true);
    await reportFile.writeAsString(report.toJsonString());
  }
  return report;
}

/// CLI-facing adapter owned by the Android delivery implementation.
Future<DeliveryVerificationReport> verifyAndroidDeliveryFromCli({
  required String aabPath,
  required String outputDirectory,
  required DeliveryVerificationOptions options,
  bool verbose = false,
}) =>
    verifyAndroidDelivery(
      aabPath: aabPath,
      outputDirectory: outputDirectory,
      deviceSpecPath: options.deviceSpecPath,
      bundletoolPath: options.toolPath,
      serial: options.deviceId,
      install: options.install,
      launch: options.launch,
      packageName: options.packageName,
      activity: options.activity,
      reportPath: options.reportPath,
      verbose: verbose,
    );
