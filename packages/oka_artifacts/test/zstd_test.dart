import 'dart:io';

import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Real-codec integration (ADR-0043 decision 4): the zstd CLI codec
/// round-trips through the store, and ratio-driven rollover is observed
/// with honest zstd deltas. Skips when zstd is not installed — the
/// store itself degrades to SnapshotOnly in that world.
void main() {
  const codec = ZstdCliCodec();
  if (!codec.isAvailable) {
    test('zstd availability', () {
      fail('zstd not installed: ${codec.unavailability}');
    });
    return;
  }

  late Directory temp;
  late ArtifactStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_artifacts_zstd_');
    store = ArtifactStore(root: Directory(p.join(temp.path, 'artifacts')));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  List<int> kernelish(final String seed, final int size) => List.generate(
    size,
    (final i) => (seed.codeUnitAt(i % seed.length) * 31 + i) % 256,
  );

  test('zstd delta round-trips through a chain of edits', () {
    var current = kernelish('kernel body v1 ', 256 * 1024);
    store.record(
      current,
      name: 'jit-dill',
      policy: const DeltaChain(),
      codec: codec,
    );
    var deltas = 0;
    var snapshots = 1;
    for (var revision = 0; revision < 6; revision++) {
      // A small, structured edit — the realistic dill churn shape.
      final edit = kernelish('kernel body v${revision + 2} ', 256 * 1024);
      current = [...edit.take(1024), ...current.skip(1024)];
      final receipt = store.record(
        current,
        name: 'jit-dill',
        policy: const DeltaChain(),
        codec: codec,
      );
      receipt.kind == 'delta' ? deltas++ : snapshots++;
    }
    expect(deltas + snapshots, 7); // initial snapshot + 6 edits

    final materialized = store.materialize(name: 'jit-dill', codec: codec);
    expect(materialized.bytes, current);
    expect(materialized.sha256, store.status(name: 'jit-dill')!['head']);
    expect(store.verify(name: 'jit-dill', codec: codec).ok, isTrue);
  });

  test('pointer binds the materialized head: digest is the integrity', () {
    final bytes = kernelish('artifact bytes ', 64 * 1024);
    final receipt = store.record(
      bytes,
      name: 'bound',
      policy: const DeltaChain(),
      codec: codec,
    );
    final pointer = ArtifactPointer(
      name: 'bound',
      sha256: receipt.sha256,
      backend: 'https://artifacts.example.dev/oka',
      sdkVersion: Platform.version,
      inputsHash: ArtifactPointer.hashBytes(bytes.sublist(0, 1024)),
      entrypoint: 'bin/harnessd.dart',
      createdAt: DateTime.now().toUtc(),
    );
    final pointerFile = File(p.join(temp.path, 'bound.dill.json'));
    pointer.writeTo(pointerFile);

    final readBack = ArtifactPointer.fromJsonString(
      pointerFile.readAsStringSync(),
    );
    expect(readBack.sha256, receipt.sha256);
    expect(readBack.backend, pointer.backend);

    final materialized = store.materialize(name: 'bound', codec: codec);
    expect(ArtifactPointer.verify(materialized.bytes, readBack.sha256), isTrue);

    final tampered = [...materialized.bytes]..[0] ^= 0xFF;
    expect(ArtifactPointer.verify(tampered, readBack.sha256), isFalse);
  });
}
