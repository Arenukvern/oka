import 'dart:io';
import 'dart:typed_data';

import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Chain semantics with deterministic codecs (ADR-0043 decisions 2–3):
/// dedup, ratio rollover, depth/cadence bounds, corrupt chains named,
/// never silently truncated.
void main() {
  late Directory temp;
  late ArtifactStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_artifacts_test_');
    store = ArtifactStore(root: Directory(p.join(temp.path, 'artifacts')));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  List<int> content(final String seed, final int size) => List.generate(
    size,
    (final i) => (seed.codeUnitAt(i % seed.length) + i) % 256,
  );

  test('first revision is a snapshot; identical content is a no-op', () {
    final bytes = content('first', 4096);
    final first = store.record(
      bytes,
      name: 'demo',
      policy: const DeltaChain(),
      codec: const XorTestCodec(),
    );
    expect(first.kind, 'snapshot');
    expect(first.degradedTo, 'first');

    final again = store.record(
      bytes,
      name: 'demo',
      policy: const DeltaChain(),
      codec: const XorTestCodec(),
    );
    expect(again.unchanged, isTrue);

    final materialized = store.materialize(name: 'demo');
    expect(materialized.bytes, bytes);
    expect(materialized.sha256, first.sha256);
  });

  test('tiny deltas chain; a huge delta rolls over to a snapshot by ratio', () {
    const codec = SharedPrefixCodec();
    var current = content('aaaabbbb', 4096);
    store.record(
      current,
      name: 'chained',
      policy: const DeltaChain(),
      codec: codec,
    );

    // Tiny edit -> tiny delta -> chain grows without a snapshot.
    for (var revision = 0; revision < 4; revision++) {
      current = [...current.sublist(0, 4090), ...content('edit$revision', 6)];
      final receipt = store.record(
        current,
        name: 'chained',
        policy: const DeltaChain(),
        codec: codec,
      );
      expect(receipt.kind, 'delta', reason: 'revision $revision');
    }
    final status = store.status(name: 'chained')!;
    expect(status['deltas'], 4);
    expect(store.materialize(name: 'chained', codec: codec).bytes, current);

    // Unrelated content -> huge delta -> ratio fires -> snapshot.
    final unrelated = content('zzzz', 4096);
    final rolled = store.record(
      unrelated,
      name: 'chained',
      policy: const DeltaChain(),
      codec: codec,
    );
    expect(rolled.kind, 'snapshot');
    expect(rolled.degradedTo, 'ratio-or-bound');
    expect(store.materialize(name: 'chained', codec: codec).bytes, unrelated);
  });

  test('maxChainDepth forces a snapshot even when deltas are tiny', () {
    const codec = SharedPrefixCodec();
    const policy = DeltaChain(maxChainDepth: 2, orEvery: 100);
    var current = content('prefix-', 2048);
    store.record(current, name: 'depth', policy: policy, codec: codec);

    for (var revision = 0; revision < 2; revision++) {
      current = [...current.sublist(0, 2040), ...content('e$revision', 8)];
      final receipt = store.record(
        current,
        name: 'depth',
        policy: policy,
        codec: codec,
      );
      expect(receipt.kind, 'delta', reason: 'revision $revision');
    }
    // Third delta would exceed depth 2 -> snapshot.
    current = [...current.sublist(0, 2040), ...content('e9', 8)];
    final receipt = store.record(
      current,
      name: 'depth',
      policy: policy,
      codec: codec,
    );
    expect(receipt.kind, 'snapshot');
    final status = store.status(name: 'depth')!;
    expect(status['deltas'], 2);
  });

  test('orEvery cadence snapshots on schedule regardless of ratios', () {
    const codec = SharedPrefixCodec();
    // orEvery: 2 -> every second revision must be a snapshot.
    const policy = DeltaChain(maxChainDepth: 100, orEvery: 2);
    var current = content('cadence', 2048);
    store.record(current, name: 'cad', policy: policy, codec: codec);
    var snapshots = 1;
    var deltas = 0;
    for (var revision = 0; revision < 6; revision++) {
      current = [...current.sublist(0, 2000), ...content('r$revision', 48)];
      final receipt = store.record(
        current,
        name: 'cad',
        policy: policy,
        codec: codec,
      );
      if (receipt.kind == 'delta') {
        deltas++;
      } else {
        snapshots++;
      }
    }
    expect(deltas, 3, reason: 'orEvery 2 allows one delta per pair');
    expect(snapshots, 4);
  });

  test('unavailable codec degrades a DeltaChain to snapshots, loudly', () {
    final bytes = content('offline', 2048);
    final first = store.record(
      bytes,
      name: 'degraded',
      policy: const DeltaChain(),
      codec: const XorTestCodec(),
    );
    final next = content('offline-next', 2048);
    final receipt = store.record(
      next,
      name: 'degraded',
      policy: const DeltaChain(),
      codec: const UnavailableCodec(),
    );
    expect(receipt.kind, 'snapshot');
    expect(receipt.degradedTo, 'codec-unavailable');
    // The chain recorded a codec name change; materialize without a
    // codec still works (snapshot-only so far in this run).
    final status = store.status(name: 'degraded')!;
    expect(status['snapshots'], greaterThanOrEqualTo(2));
    expect(first.sha256, isNot(receipt.sha256));
  });

  test('corrupt chains are named, never silently truncated', () {
    final bytes = content('keepme', 2048);
    store.record(
      bytes,
      name: 'broken',
      policy: const SnapshotOnly(),
      codec: const XorTestCodec(),
    );
    // Delete the snapshot blob out from under the chain.
    final sha = store.materialize(name: 'broken').sha256;
    File(p.join(store.root.path, 'blobs', sha)).deleteSync();

    final report = store.verify(name: 'broken', codec: const XorTestCodec());
    expect(report.ok, isFalse);
    expect(report.problems.single, contains('missing snapshot blob'));
    expect(
      () => store.materialize(name: 'broken', codec: const XorTestCodec()),
      throwsA(isA<ArtifactStoreCorruptException>()),
    );
  });

  test('materialize without a codec names the problem when deltas exist', () {
    const codec = SharedPrefixCodec();
    var current = content('needscodec', 1024);
    store.record(
      current,
      name: 'deltas',
      policy: const DeltaChain(),
      codec: codec,
    );
    current = [...current.sublist(0, 1020), ...content('x', 4)];
    store.record(
      current,
      name: 'deltas',
      policy: const DeltaChain(),
      codec: codec,
    );

    expect(
      () => store.materialize(name: 'deltas'),
      throwsA(
        isA<ArtifactStoreCorruptException>().having(
          (final e) => e.problems.single,
          'problems',
          contains('no codec was provided'),
        ),
      ),
    );
    // Snapshot-only chains materialize without one.
    store.record(
      current,
      name: 'plain',
      policy: const SnapshotOnly(),
      codec: const XorTestCodec(),
    );
    expect(store.materialize(name: 'plain').bytes, current);
  });

  test('snapshot-only strategy never stores deltas', () {
    const codec = SharedPrefixCodec();
    var current = content('snap', 1024);
    store.record(
      current,
      name: 'only',
      policy: const SnapshotOnly(),
      codec: codec,
    );
    for (var revision = 0; revision < 3; revision++) {
      current = [...current.sublist(0, 1020), ...content('s$revision', 4)];
      final receipt = store.record(
        current,
        name: 'only',
        policy: const SnapshotOnly(),
        codec: codec,
      );
      expect(receipt.kind, 'snapshot');
      expect(receipt.degradedTo, isNull);
    }
    final status = store.status(name: 'only')!;
    expect(status['deltas'], 0);
    expect(status['snapshots'], 4);
  });

  test('invalid artifact names are rejected before any write', () {
    expect(
      () => store.record(
        content('x', 8),
        name: '../escape',
        policy: const SnapshotOnly(),
        codec: const XorTestCodec(),
      ),
      throwsArgumentError,
    );
    expect(store.names(), isEmpty);
  });
}

final class UnavailableCodec implements DeltaCodec {
  const UnavailableCodec();

  @override
  String get name => 'unavailable';

  @override
  bool get isAvailable => false;

  @override
  String? get unavailability => 'test codec is never available';

  @override
  Uint8List delta({
    required final List<int> base,
    required final List<int> target,
  }) => throw UnsupportedError('unavailable');

  @override
  Uint8List undelta({
    required final List<int> base,
    required final Uint8List deltaBytes,
  }) => throw UnsupportedError('unavailable');
}
