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

Future<void> _seedStore(
  final String cacheRoot, {
  required String coordinate,
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
    _paddedJarBytes(),
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
    temp = await Directory.systemTemp.createTemp('oka_extra_deps_selection');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('selection narrows the embedding set to the version winners', () async {
    // The embedding set (dependency-resolve) holds camera-core 1.4.2; the
    // extra-deps transitive closure resolves camera-core 1.6.1. The winner
    // must REPLACE the embedding entry: a loser riding along splits
    // versions across the dex, which broke CameraX provider resolution at
    // runtime while every compile-time symbol resolved cleanly.
    await _seedStore(
      p.join(temp.path, 'maven'),
      coordinate: 'com.example:camera-core:1.6.1',
    );
    final oldEmbedding = p.join(
      temp.path,
      'maven',
      'com',
      'example',
      'camera-core',
      '1.4.2',
      'camera-core-1.4.2-classes.jar',
    );
    final cache = DependencyCache(
      cacheRoot: p.join(temp.path, 'maven'),
      allowNetwork: false,
    );
    final state = PipelineState()
      ..androidxJars = [
        ResolvedJar(
          coordinate: MavenCoordinate.parse('com.example:camera-core:1.4.2')!,
          jarPath: oldEmbedding,
        ),
      ];

    final result = await ExtraDepsStep([
      'com.example:camera-core:1.6.1',
    ], cache).run(_ctx(temp.path, p.join(temp.path, 'build')), state);

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(
      state.androidxJars,
      isEmpty,
      reason: 'the embedding 1.4.2 lost to the transitive 1.6.1 and must '
          'leave androidxJars entirely',
    );
    expect(state.extraRuntimeJars, hasLength(1));
    expect(
      state.extraRuntimeJars.single,
      endsWith('camera-core-1.6.1-classes.jar'),
    );
    expect(
      state.extraRuntimeJars.join(),
      isNot(contains('camera-core-1.4.2')),
    );
  });
}
