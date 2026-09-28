import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/android_state.dart';
import 'package:oka_android/src/pipeline/steps/flutter_steps.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ArchiveFile _textFile(final String name, final String content) =>
    ArchiveFile(name, content.length, content.codeUnits);

/// ADR-0028 §3: engine extraction is fingerprinted (StepCache), stored once
/// per machine keyed by engine-jar identity, and materialized into project
/// buildDirs through the link chain.
void main() {
  late Directory temp;
  late String sdkPath;
  late LocalArtifactStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_engine_step_');
    sdkPath = p.join(temp.path, 'flutter-sdk');
    store = LocalArtifactStore(root: p.join(temp.path, 'store'));

    // Fixture engine jar: one ABI's libflutter.so + embedding classes.
    final archive = Archive()
      ..addFile(_textFile('lib/arm64-v8a/libflutter.so', 'SO-BYTES'))
      ..addFile(_textFile('io/flutter/Embedding.class', 'CLASS-BYTES'))
      ..addFile(_textFile('META-INF/MANIFEST.MF', 'Manifest-Version: 1'));
    final engineDir = p.join(
      sdkPath,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'android-arm64',
    );
    Directory(engineDir).createSync(recursive: true);
    File(
      p.join(engineDir, 'flutter.jar'),
    ).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  BuildContext contextFor(final String name) {
    final project = temp.createTempSync(name);
    final buildDir = p.join(project.path, '.oka_cache', 'build', 'debug');
    Directory(buildDir).createSync(recursive: true);
    return BuildContext(
      projectPath: project.path,
      buildDir: buildDir,
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      flutterSdkPath: sdkPath,
    );
  }

  test('first run extracts, registers store entries, materializes outputs',
      () async {
    final ctx = contextFor('app_a');
    final state = PipelineState()..abis = ['arm64-v8a'];
    final result = await EngineExtractionStep(store: store).run(ctx, state);

    expect(result.ok, isTrue, reason: result.error);
    final so = File(
      p.join(ctx.buildDir, 'lib', 'arm64-v8a', 'libflutter.so'),
    );
    expect(so.readAsStringSync(), 'SO-BYTES');
    expect(
      File(
        p.join(ctx.buildDir, 'flutter_embedding_classes.jar'),
      ).lengthSync(),
      greaterThan(0),
    );
    expect(state.libflutterByAbi['arm64-v8a'], so.path);
    expect(state.embeddingJar, endsWith('flutter_embedding_classes.jar'));

    final engineEntries = (await store.entries())
        .where((final e) => e.key.category == 'engine')
        .toList();
    expect(engineEntries.map((final e) => e.key.name), containsAll([
      'libflutter',
      'flutter-embedding',
    ]));
  });

  test('second run with unchanged engine is a StepCache hit (no re-extract)',
      () async {
    final ctx = contextFor('app_a');
    await EngineExtractionStep(store: store).run(ctx, PipelineState()
      ..abis = ['arm64-v8a']);

    // Tamper with the materialized output: a cache hit must NOT restore it.
    final so = File(p.join(ctx.buildDir, 'lib', 'arm64-v8a', 'libflutter.so'));
    so.writeAsStringSync('TAMPERED');
    final state = PipelineState()..abis = ['arm64-v8a'];
    final result = await EngineExtractionStep(store: store).run(ctx, state);

    expect(result.ok, isTrue, reason: result.error);
    expect(so.readAsStringSync(), 'TAMPERED');
  });

  test('a second project materializes from the store without re-extracting',
      () async {
    final first = contextFor('app_a');
    await EngineExtractionStep(
      store: store,
    ).run(first, PipelineState()..abis = ['arm64-v8a']);
    final entriesBefore = (await store.entries())
        .where((final e) => e.key.category == 'engine')
        .length;

    final second = contextFor('app_b');
    final state = PipelineState()..abis = ['arm64-v8a'];
    final result = await EngineExtractionStep(store: store).run(second, state);

    expect(result.ok, isTrue, reason: result.error);
    expect(
      File(
        p.join(second.buildDir, 'lib', 'arm64-v8a', 'libflutter.so'),
      ).readAsStringSync(),
      'SO-BYTES',
    );
    final entriesAfter = (await store.entries())
        .where((final e) => e.key.category == 'engine')
        .length;
    expect(entriesAfter, entriesBefore, reason: 'no new store entries');
  });
}
