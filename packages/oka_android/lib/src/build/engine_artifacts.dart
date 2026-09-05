import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'apk_layout.dart';

/// Locates and extracts Flutter engine artifacts from a Flutter SDK tree.
class EngineArtifacts {
  final String flutterSdkPath;
  final bool verbose;

  EngineArtifacts(this.flutterSdkPath, {this.verbose = false});

  String get engineRoot =>
      p.join(flutterSdkPath, 'bin', 'cache', 'artifacts', 'engine');

  /// Path to the ABI-specific flutter.jar (contains classes + libflutter.so).
  Future<String?> findFlutterJar(String abi, {required bool release}) async {
    final dirName = engineArtifactDirForAbi(abi, release: release);
    final jar = p.join(engineRoot, dirName, 'flutter.jar');
    if (await File(jar).exists()) {
      return jar;
    }
    // Fall back to non-release jar for missing release dirs.
    if (release) {
      final debugJar = p.join(
        engineRoot,
        engineArtifactDirForAbi(abi, release: false),
        'flutter.jar',
      );
      if (await File(debugJar).exists()) return debugJar;
    }
    return null;
  }

  /// Extract `lib/<abi>/libflutter.so` from flutter.jar into [destSoPath].
  Future<String> extractLibflutter({
    required String abi,
    required String destSoPath,
    required bool release,
  }) async {
    final jarPath = await findFlutterJar(abi, release: release);
    if (jarPath == null) {
      throw Exception(
        'flutter.jar not found for ABI $abi under $engineRoot. '
        'Run: flutter precache --android',
      );
    }

    final bytes = await File(jarPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final abiNorm = normalizeAbi(abi);
    final candidates = [
      'lib/$abiNorm/libflutter.so',
      'libflutter.so',
    ];

    ArchiveFile? soFile;
    for (final name in candidates) {
      for (final f in archive) {
        if (f.isFile && f.name.replaceAll(r'\', '/') == name) {
          soFile = f;
          break;
        }
      }
      if (soFile != null) break;
    }

    // Any libflutter.so in the jar
    if (soFile == null) {
      for (final f in archive) {
        if (f.isFile && f.name.endsWith('libflutter.so')) {
          soFile = f;
          break;
        }
      }
    }

    if (soFile == null) {
      throw Exception('libflutter.so not found inside $jarPath');
    }

    await File(destSoPath).parent.create(recursive: true);
    await File(destSoPath).writeAsBytes(soFile.content as List<int>);
    if (verbose) {
      print('   Extracted libflutter.so ($abiNorm) → $destSoPath');
    }
    return destSoPath;
  }

  /// Extract all requested ABIs' libflutter.so into [libDir]/abi}/libflutter.so.
  Future<Map<String, String>> extractLibflutterForAbis({
    required List<String> abis,
    required String libDir,
    required bool release,
  }) async {
    final result = <String, String>{};
    for (final abi in abis) {
      final n = normalizeAbi(abi);
      final dest = p.join(libDir, n, 'libflutter.so');
      await extractLibflutter(abi: n, destSoPath: dest, release: release);
      result[n] = dest;
    }
    return result;
  }

  /// Extract only `.class` entries from [flutterJar] into a clean JAR for d8/javac.
  ///
  /// Engine `flutter.jar` also contains `lib/**/*.so` which break d8 when passed
  /// as a whole archive.
  Future<String> extractEmbeddingClassesJar({
    required String flutterJar,
    required String destJarPath,
  }) async {
    final bytes = await File(flutterJar).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final out = Archive();
    var count = 0;
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll(r'\', '/');
      if (name.endsWith('.class') ||
          name.startsWith('META-INF/') ||
          name.endsWith('.kotlin_module')) {
        out.addFile(ArchiveFile(name, f.size, f.content));
        count++;
      }
    }
    if (count == 0) {
      throw Exception('No .class entries found in $flutterJar');
    }
    final encoded = ZipEncoder().encode(out);
    if (encoded == null) {
      throw Exception('Failed to encode embedding classes jar');
    }
    await File(destJarPath).parent.create(recursive: true);
    await File(destJarPath).writeAsBytes(encoded, flush: true);
    if (verbose) {
      print('   Extracted $count class entries → $destJarPath');
    }
    return destJarPath;
  }

  /// Find ICU data file if present in engine artifacts.
  Future<String?> findIcuData() async {
    final candidates = [
      p.join(engineRoot, 'android-arm64', 'icudtl.dat'),
      p.join(engineRoot, 'common', 'icudtl.dat'),
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    // Search flutter.jar
    final jar = await findFlutterJar('arm64-v8a', release: false);
    if (jar != null) {
      final bytes = await File(jar).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive) {
        if (f.isFile && f.name.endsWith('icudtl.dat')) {
          final out = p.join(
            Directory.systemTemp.path,
            'oka_icu_${f.name.hashCode}.dat',
          );
          await File(out).writeAsBytes(f.content as List<int>);
          return out;
        }
      }
    }
    return null;
  }
}
