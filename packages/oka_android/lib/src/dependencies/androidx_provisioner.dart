import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../tools/tool_host.dart';

typedef TempDirectoryFactory = Future<Directory> Function(String prefix);

Future<Directory> createToolTempDirectory(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

/// Provisions the fixed AndroidX bootstrap artifacts used by host compilation.
/// Legacy cache reads remain supported; new artifacts use [ArtifactStore].
class AndroidxJarProvisioner {
  AndroidxJarProvisioner({
    ArtifactStore? store,
    Map<String, String>? environment,
    this.processRunner = runToolProcess,
    this.tempDirectoryFactory = createToolTempDirectory,
  }) : _store = store ?? LocalArtifactStore(environment: environment),
       environment = environment ?? Platform.environment;

  final ArtifactStore _store;
  final Map<String, String> environment;
  final ToolProcessRunner processRunner;
  final TempDirectoryFactory tempDirectoryFactory;

  Future<String> findAndroidXAnnotations() => _androidXJar(
    name: 'annotation-jvm',
    version: '1.9.1',
    legacyFileName: 'annotation-jvm-1.9.1.jar',
    miss: (tmp) => _download(
      url:
          'https://maven.google.com/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar',
      fileName: 'annotation-jvm-1.9.1.jar',
      tmpDir: tmp,
    ),
  );

  Future<String> findAndroidXLifecycle() => _androidXJar(
    name: 'lifecycle-common-jvm',
    version: '2.8.7',
    legacyFileName: 'lifecycle-common-jvm-2.8.7.jar',
    miss: (tmp) => _download(
      url:
          'https://maven.google.com/androidx/lifecycle/lifecycle-common-jvm/2.8.7/lifecycle-common-jvm-2.8.7.jar',
      fileName: 'lifecycle-common-jvm-2.8.7.jar',
      tmpDir: tmp,
    ),
  );

  Future<String> findAndroidXLifecycleRuntime() => _androidXJar(
    name: 'lifecycle-runtime',
    version: '2.8.7',
    legacyFileName: 'lifecycle-runtime-2.8.7.jar',
    miss: (tmp) async {
      final aar = await _download(
        url:
            'https://maven.google.com/androidx/lifecycle/lifecycle-runtime/2.8.7/lifecycle-runtime-2.8.7.aar',
        fileName: 'lifecycle-runtime-2.8.7.aar',
        tmpDir: tmp,
      );
      print('   Extracting classes.jar from AAR...');
      final result = await processRunner('unzip', [
        '-j',
        aar.path,
        'classes.jar',
        '-d',
        tmp,
      ]);
      if (result.exitCode != 0) {
        throw Exception('Failed to extract classes.jar: ${result.stderr}');
      }
      final jar = await File(
        p.join(tmp, 'classes.jar'),
      ).rename(p.join(tmp, 'lifecycle-runtime-2.8.7.jar'));
      await aar.delete();
      return jar;
    },
  );

  Future<String> _androidXJar({
    required String name,
    required String version,
    required String legacyFileName,
    required Future<File> Function(String tmpDir) miss,
  }) async {
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
    final legacy = File(
      p.join(home, '.oka', 'cache', 'androidx', legacyFileName),
    );
    if (await legacy.exists()) return legacy.path;

    print('📥 Downloading AndroidX $name $version from Google Maven...');
    final key = ContentKey.compute(
      category: 'androidx',
      name: name,
      version: version,
      inputs: ['google-maven:$name:$version'],
    );
    final tmp = await tempDirectoryFactory('oka_androidx_');
    try {
      final stored = await _store.fetch(key, () => miss(tmp.path));
      print(
        '   File size: ${(await stored.length() / 1024).toStringAsFixed(2)} KB',
      );
      print('✅ Cached at: ${stored.path}');
      return stored.path;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Best-effort temporary cleanup.
      }
    }
  }

  Future<File> _download({
    required String url,
    required String fileName,
    required String tmpDir,
  }) async {
    final target = File(p.join(tmpDir, fileName));
    print('   URL: $url');
    print('   Target: ${target.path}');
    final result = await processRunner(
      'curl',
      ['-L', '-f', '-o', target.path, '--progress-bar', url],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    if (result.exitCode != 0) {
      final error = result.stderr == null
          ? 'Unknown error'
          : String.fromCharCodes(result.stderr as List<int>);
      throw Exception('Download failed (exit code ${result.exitCode}): $error');
    }
    if (!await target.exists()) {
      throw Exception('Downloaded file not found at: ${target.path}');
    }
    if (await target.length() < 1000) {
      await target.delete();
      throw Exception('Downloaded file is too small (possibly invalid)');
    }
    return target;
  }
}
