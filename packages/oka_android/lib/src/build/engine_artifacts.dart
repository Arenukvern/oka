import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'apk_layout.dart';

/// Engine cache-dir suffix for a build mode: debug → `''`, profile →
/// `'-profile'`, release → `'-release'`.
///
/// Each mode pairs only with its own engine build (see
/// [engineArtifactDirForVariant] for why cross-pairing is fatal).
String engineVariantForMode(final BuildMode mode) {
  switch (mode) {
    case BuildMode.debug:
      return '';
    case BuildMode.profile:
      return '-profile';
    case BuildMode.release:
      return '-release';
  }
}

/// Locates and extracts Flutter engine artifacts from a Flutter SDK tree.
class EngineArtifacts {

  EngineArtifacts(this.flutterSdkPath, {this.verbose = false});
  final String flutterSdkPath;
  final bool verbose;

  String get engineRoot =>
      p.join(flutterSdkPath, 'bin', 'cache', 'artifacts', 'engine');

  /// Path to the ABI-variant-specific flutter.jar (classes + libflutter.so).
  ///
  /// Returns null when the jar for exactly this [variant] is absent — never
  /// falls back to another variant's jar: pairing the debug (JIT) engine
  /// with a release AOT snapshot produces apps that hang on the splash
  /// forever. Use [ensureEngineJars] to populate the cache on demand.
  Future<String?> findFlutterJar(final String abi,
      {required final String variant}) async {
    final dirName = engineArtifactDirForVariant(abi, variant: variant);
    final jar = p.join(engineRoot, dirName, 'flutter.jar');
    if (await File(jar).exists()) {
      return jar;
    }
    return null;
  }

  /// Resolves the per-ABI flutter.jar for [variant], running
  /// `flutter precache --android` once when a jar is missing.
  ///
  /// `flutter assemble` downloads gen_snapshot but never the engine jars, so
  /// a release build on a fresh SDK cache misses them. Throws when jars are
  /// still missing after the cache update — a wrong-variant engine is never
  /// substituted.
  Future<Map<String, String>> ensureEngineJars({
    required final List<String> abis,
    required final String variant,
    final String? workingDirectory,
    final Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    })? runProcess,
    final void Function(String message)? log,
  }) async {
    final runner = runProcess ?? Process.run;
    final say = log ?? print;
    final resolved = <String, String>{};
    final missing = <String>[];
    for (final abi in abis) {
      final jar = await findFlutterJar(abi, variant: variant);
      if (jar == null) {
        missing.add(normalizeAbi(abi));
      } else {
        resolved[normalizeAbi(abi)] = jar;
      }
    }
    if (missing.isEmpty) return resolved;

    final variantName = variant.isEmpty ? 'debug' : variant.substring(1);
    say(
      '🧩 flutter.jar ($variantName) missing for ${missing.join(', ')} — '
      'running flutter precache --android ...',
    );
    final result = await runner(
      'flutter',
      const ['precache', '--android'],
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      throw Exception(
        'flutter precache --android failed (exit ${result.exitCode}):\n'
        '${result.stderr}\n${result.stdout}',
      );
    }
    for (final abi in missing) {
      final jar = await findFlutterJar(abi, variant: variant);
      if (jar == null) {
        throw Exception(
          'flutter.jar ($variantName) still missing for $abi under '
          '$engineRoot after `flutter precache --android`.\n'
          'Refusing to substitute another engine variant — that ships apps '
          'which hang on the splash screen (release AOT snapshot needs the '
          'release engine).\n'
          'Fix: run `flutter doctor -v`, then `flutter precache --android`, '
          'or upgrade Flutter if the cache stays incomplete.',
        );
      }
      resolved[abi] = jar;
    }
    return resolved;
  }

  /// Extract `lib/<abi>/libflutter.so` from [flutterJar] into [destSoPath].
  Future<String> extractLibflutterFromJar({
    required final String flutterJar,
    required final String abi,
    required final String destSoPath,
  }) async {
    final bytes = await File(flutterJar).readAsBytes();
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
      throw Exception('libflutter.so not found inside $flutterJar');
    }

    await File(destSoPath).parent.create(recursive: true);
    await File(destSoPath).writeAsBytes(soFile.content as List<int>);
    if (verbose) {
      print('   Extracted libflutter.so ($abiNorm) → $destSoPath');
    }
    return destSoPath;
  }

  /// Resolve the variant flutter.jar, then extract its libflutter.so.
  Future<String> extractLibflutter({
    required final String abi,
    required final String destSoPath,
    required final String variant,
  }) async {
    final jarPath = await findFlutterJar(abi, variant: variant);
    if (jarPath == null) {
      final dirName = engineArtifactDirForVariant(abi, variant: variant);
      throw Exception(
        'flutter.jar not found for ABI $abi under '
        '${p.join(engineRoot, dirName)}. Run: flutter precache --android',
      );
    }
    return extractLibflutterFromJar(
      flutterJar: jarPath,
      abi: abi,
      destSoPath: destSoPath,
    );
  }

  /// Extract all requested ABIs' libflutter.so into [libDir]/abi}/libflutter.so.
  Future<Map<String, String>> extractLibflutterForAbis({
    required final List<String> abis,
    required final String libDir,
    required final String variant,
  }) async {
    final result = <String, String>{};
    for (final abi in abis) {
      final n = normalizeAbi(abi);
      final dest = p.join(libDir, n, 'libflutter.so');
      await extractLibflutter(abi: n, destSoPath: dest, variant: variant);
      result[n] = dest;
    }
    return result;
  }

  /// Extract only `.class` entries from [flutterJar] into a clean JAR for d8/javac.
  ///
  /// Engine `flutter.jar` also contains `lib/**/*.so` which break d8 when passed
  /// as a whole archive.
  Future<String> extractEmbeddingClassesJar({
    required final String flutterJar,
    required final String destJarPath,
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
    final encoded = ZipEncoder().encodeBytes(out);
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
    final jar = await findFlutterJar('arm64-v8a', variant: '');
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
