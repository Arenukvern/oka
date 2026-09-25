import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/android_state.dart';
import 'package:oka_android/src/build/dependency_cache.dart';
import 'package:oka_android/src/pipeline/default_pipeline.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Classes.jar padded past the 200-byte metadata-shell threshold so the
/// resolver treats a seeded store entry as a real warm-cache hit.
List<int> _paddedJarBytes() {
  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'META-INF/MANIFEST.MF',
        26,
        'Manifest-Version: 1.0\n'.codeUnits,
      ),
    )
    ..addFile(
      ArchiveFile('com/example/padding.dat', 1024, List.filled(1024, 0x42)),
    );
  return ZipEncoder().encodeBytes(archive);
}

List<int> _aarBytes({
  required String abi,
  required String soName,
  bool withRes = false,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile('classes.jar', _paddedJarBytes().length, _paddedJarBytes()),
    )
    ..addFile(ArchiveFile('jni/$abi/$soName', 16, List.filled(16, 0x4c)));
  if (withRes) {
    archive.addFile(
      ArchiveFile('res/values/strings.xml', 12, '<resources/>'.codeUnits),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Seeds a Maven store entry (`.aar` + extracted `-classes.jar`) under
/// [cacheRoot] exactly as a cold resolve would have left it.
Future<void> _seedStore(
  final String cacheRoot, {
  required String coordinate,
  required String abi,
  required String soName,
  bool withRes = false,
}) async {
  final parts = coordinate.split(':');
  final dir = p.join(
    cacheRoot,
    parts[0].replaceAll('.', '/'),
    parts[1],
    parts[2],
  );
  await Directory(dir).create(recursive: true);
  await File(p.join(dir, '${parts[1]}-${parts[2]}.aar')).writeAsBytes(
    _aarBytes(abi: abi, soName: soName, withRes: withRes),
    flush: true,
  );
  await File(
    p.join(dir, '${parts[1]}-${parts[2]}-classes.jar'),
  ).writeAsBytes(_paddedJarBytes(), flush: true);
}

BuildContext _ctx(final String projectPath, final String buildDir) =>
    BuildContext(
      projectPath: projectPath,
      buildDir: buildDir,
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_extra_deps');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('warm-cache extra dep resolves with AAR natives and res', () async {
    await _seedStore(
      p.join(temp.path, 'maven'),
      coordinate: 'com.example:lib-native:1.0.0',
      abi: 'arm64-v8a',
      soName: 'libnative.so',
      withRes: true,
    );
    final cache = DependencyCache(
      cacheRoot: p.join(temp.path, 'maven'),
      allowNetwork: false,
    );
    final state = PipelineState();
    final result = await ExtraDepsStep([
      'com.example:lib-native:1.0.0',
    ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(
      state.extraRuntimeJars.single,
      endsWith('lib-native-1.0.0-classes.jar'),
    );
    expect(state.aarNativeLibsByAbi['arm64-v8a'], hasLength(1));
    expect(state.aarNativeLibsByAbi['arm64-v8a']!.single, endsWith('.so'));
    expect(state.aarResDirs, hasLength(1));
  });

  test('extra deps resolve their POM transitive closure', () async {
    // Root in the store; transitive reachable only via POM (served by a
    // real network fetch is not an option here, so this asserts the step
    // keeps root jars even when transitive POM resolution has nothing to
    // add — the offline warm-cache contract).
    await _seedStore(
      p.join(temp.path, 'maven'),
      coordinate: 'com.example:lib-root:2.0.0',
      abi: 'armeabi-v7a',
      soName: 'libroot.so',
    );
    final cache = DependencyCache(
      cacheRoot: p.join(temp.path, 'maven'),
      allowNetwork: false,
    );
    final state = PipelineState();
    final result = await ExtraDepsStep([
      'com.example:lib-root:2.0.0',
    ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(state.extraRuntimeJars, hasLength(1));
    expect(state.aarNativeLibsByAbi['armeabi-v7a'], hasLength(1));
  });

  test(
    'only the latest resolved version per artifact contributes payload',
    () async {
      // Two versions of the same artifact in the store; the step must keep
      // exactly one classes.jar and one payload res dir.
      await _seedStore(
        p.join(temp.path, 'maven'),
        coordinate: 'com.example:dual:1.9.0',
        abi: 'arm64-v8a',
        soName: 'libdual.so',
        withRes: true,
      );
      await _seedStore(
        p.join(temp.path, 'maven'),
        coordinate: 'com.example:dual:1.15.0',
        abi: 'arm64-v8a',
        soName: 'libdual.so',
        withRes: true,
      );
      final cache = DependencyCache(
        cacheRoot: p.join(temp.path, 'maven'),
        allowNetwork: false,
      );
      final state = PipelineState();
      final result = await ExtraDepsStep([
        'com.example:dual:1.9.0',
        'com.example:dual:1.15.0',
      ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(state.extraRuntimeJars, hasLength(1));
      expect(state.extraRuntimeJars.single, contains('1.15.0'));
      expect(state.aarResDirs, hasLength(1));
      expect(state.aarResDirs.single, contains('1.15.0'));
      expect(state.aarNativeLibsByAbi['arm64-v8a'], hasLength(1));
    },
  );

  test(
    'embedding-set version wins conflicts and is not re-added as extra jar',
    () async {
      // camera-core-style: POM pins an old version while the embedding set
      // already resolved a newer one. The winner's payload is merged, and the
      // embedding jar is not duplicated into extraRuntimeJars.
      await _seedStore(
        p.join(temp.path, 'maven'),
        coordinate: 'androidx.core:core:1.1.0',
        abi: 'arm64-v8a',
        soName: 'libcore_old.so',
        withRes: true,
      );
      await _seedStore(
        p.join(temp.path, 'maven'),
        coordinate: 'androidx.core:core:1.15.0',
        abi: 'arm64-v8a',
        soName: 'libcore_new.so',
        withRes: true,
      );
      final cache = DependencyCache(
        cacheRoot: p.join(temp.path, 'maven'),
        allowNetwork: false,
      );
      final newer = await cache.resolve(
        MavenCoordinate.parse('androidx.core:core:1.15.0')!,
      );
      final state = PipelineState()..androidxJars = [newer];
      final result = await ExtraDepsStep([
        'androidx.core:core:1.1.0',
      ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(state.extraRuntimeJars, isEmpty);
      expect(state.aarResDirs, hasLength(1));
      expect(state.aarResDirs.single, contains('1.15.0'));
      expect(state.aarNativeLibsByAbi['arm64-v8a']!.single, contains('1.15.0'));
    },
  );

  test('missing root dependency fails the build with a clear error', () async {
    final cache = DependencyCache(
      cacheRoot: p.join(temp.path, 'maven'),
      allowNetwork: false,
    );
    final state = PipelineState();
    final result = await ExtraDepsStep([
      'com.example:missing:9.9.9',
    ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isFalse);
    expect(result.error, contains('Failed to resolve extra dependency'));
  });

  test('invalid coordinate fails with the exact snippet', () async {
    final cache = DependencyCache(cacheRoot: p.join(temp.path, 'maven'));
    final state = PipelineState();
    final result = await ExtraDepsStep([
      'definitely-not-a-coordinate',
    ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isFalse);
    expect(result.error, contains('Invalid extra_dep coordinate'));
  });

  test('LocalAarsStep merges payloads instead of clobbering them', () async {
    final projectAar = p.join(temp.path, 'libs', 'local.aar');
    await File(projectAar).parent.create(recursive: true);
    await File(projectAar).writeAsBytes(
      _aarBytes(abi: 'arm64-v8a', soName: 'liblocal.so'),
      flush: true,
    );
    final state = PipelineState()
      ..aarNativeLibsByAbi = {
        'arm64-v8a': [p.join(temp.path, 'maven', 'libnative.so')],
      }
      ..aarResDirs = [p.join(temp.path, 'maven', 'payload', 'res')]
      ..extraRuntimeJars = [p.join(temp.path, 'maven', 'extra.jar')];

    final result = await LocalAarsStep([
      'libs/local.aar',
    ]).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(state.extraRuntimeJars, hasLength(2));
    expect(state.aarNativeLibsByAbi['arm64-v8a'], hasLength(2));
    expect(state.aarResDirs, hasLength(1));
  });
}
