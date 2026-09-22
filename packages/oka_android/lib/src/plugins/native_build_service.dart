import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/toolchain.dart';
import '../compilation/process_runner.dart';

// Native compilation is an injectable capability used by plugin orchestration.
// ignore: one_member_abstracts
abstract interface class NativeBuildService {
  Future<Map<String, String>> build({
    required String pluginPath,
    required String workDir,
    required List<String> abis,
  });
}

class CmakeNativeBuildService implements NativeBuildService {
  CmakeNativeBuildService({
    required this.toolchain,
    this.verbose = false,
    this.processRunner = runAndroidProcess,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final ResolvedToolchain toolchain;
  final bool verbose;
  final AndroidProcessRunner processRunner;
  final Map<String, String> environment;

  @override
  Future<Map<String, String>> build({
    required String pluginPath,
    required String workDir,
    required List<String> abis,
  }) async {
    var source = p.join(pluginPath, 'src');
    if (!await File(p.join(source, 'CMakeLists.txt')).exists()) {
      source = p.join(pluginPath, 'android');
      if (!await File(p.join(source, 'CMakeLists.txt')).exists()) {
        throw Exception('CMakeLists.txt not found under $pluginPath/src');
      }
    }
    final androidSdk = await toolchain.findAndroidSdk();
    final ndk = await findNdkHome(androidSdk, environment: environment);
    if (ndk == null) {
      throw Exception(
        'Android NDK not found under $androidSdk. '
        'Install with: sdkmanager "ndk;27.0.12077973"',
      );
    }
    final cmake = await findCmake(androidSdk, processRunner: processRunner);
    if (cmake == null) {
      throw Exception(
        'CMake not found. Install Android SDK cmake or system cmake.',
      );
    }
    final toolchainFile = p.join(
      ndk,
      'build',
      'cmake',
      'android.toolchain.cmake',
    );
    if (!await File(toolchainFile).exists()) {
      throw Exception('NDK toolchain missing: $toolchainFile');
    }
    final output = <String, String>{};
    for (final abi in [...abis]..sort()) {
      final outDir = p.join(workDir, abi);
      await Directory(outDir).create(recursive: true);
      final configure = await processRunner(cmake, [
        '-S',
        source,
        '-B',
        outDir,
        '-DCMAKE_TOOLCHAIN_FILE=$toolchainFile',
        '-DANDROID_ABI=$abi',
        '-DANDROID_PLATFORM=android-21',
        '-DANDROID_STL=c++_static',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DANDROID=TRUE',
      ]);
      if (configure.exitCode != 0) {
        throw Exception(
          'cmake configure failed for $abi: '
          '${configure.stderr}\n${configure.stdout}',
        );
      }
      final compiled = await processRunner(cmake, [
        '--build',
        outDir,
        '--config',
        'Release',
        '-j',
        '${Platform.numberOfProcessors}',
      ]);
      if (compiled.exitCode != 0) {
        throw Exception(
          'cmake build failed for $abi: ${compiled.stderr}\n${compiled.stdout}',
        );
      }
      final libraries = <String>[];
      await for (final entry in Directory(outDir).list(recursive: true)) {
        if (entry is File && entry.path.endsWith('.so')) {
          libraries.add(entry.path);
        }
      }
      libraries.sort((left, right) {
        final leftPreferred = p.basename(left).contains('dartjni') ? 0 : 1;
        final rightPreferred = p.basename(right).contains('dartjni') ? 0 : 1;
        return leftPreferred != rightPreferred
            ? leftPreferred.compareTo(rightPreferred)
            : left.compareTo(right);
      });
      if (libraries.isEmpty) {
        throw Exception('No .so produced for ABI $abi under $outDir');
      }
      output[abi] = libraries.first;
      if (verbose) {
        print('   native $abi (${ndkAbiTriple(abi)}): ${libraries.first}');
      }
    }
    return output;
  }
}

String ndkAbiTriple(String abi) => switch (abi) {
  'arm64-v8a' => 'aarch64-linux-android',
  'armeabi-v7a' => 'armv7a-linux-androideabi',
  'x86_64' => 'x86_64-linux-android',
  'x86' => 'i686-linux-android',
  _ => abi,
};

Future<String?> findNdkHome(
  String androidSdk, {
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final configured = env['ANDROID_NDK_HOME'] ?? env['NDK_HOME'];
  if (configured != null && await Directory(configured).exists()) {
    return configured;
  }
  final root = Directory(p.join(androidSdk, 'ndk'));
  if (await root.exists()) {
    final versions = <String>[];
    await for (final entry in root.list()) {
      if (entry is Directory) versions.add(p.basename(entry.path));
    }
    if (versions.isNotEmpty) {
      versions.sort();
      return p.join(root.path, versions.last);
    }
  }
  final bundle = p.join(androidSdk, 'ndk-bundle');
  return await Directory(bundle).exists() ? bundle : null;
}

Future<String?> findCmake(
  String androidSdk, {
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  final root = Directory(p.join(androidSdk, 'cmake'));
  if (await root.exists()) {
    final versions = <String>[];
    await for (final entry in root.list()) {
      if (entry is Directory) versions.add(p.basename(entry.path));
    }
    versions.sort();
    for (final version in versions.reversed) {
      final binary = p.join(root.path, version, 'bin', 'cmake');
      if (await File(binary).exists()) return binary;
    }
  }
  try {
    final result = await processRunner('which', ['cmake']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
  } catch (_) {}
  return null;
}
