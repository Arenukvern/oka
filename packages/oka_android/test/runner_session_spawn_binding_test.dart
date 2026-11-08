import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

final class _FixedTreeProbe implements ProcessTreeProbe {
  const _FixedTreeProbe(this.parentOf);

  final Map<int, int> parentOf;

  @override
  Future<ProcessTree?> enumerate(int rootPid) async =>
      ProcessTree(rootPid: rootPid, parentOf: parentOf);
}

void main() {
  group('verifyRunnerSessionSpawnBindingPids', () {
    test('exact match', () async {
      final r = await verifyRunnerSessionSpawnBindingPids(
        discoveryPid: 100,
        spawnPid: 100,
        probe: const _FixedTreeProbe({100: 1}),
      );
      expect(r.binding, RunnerSessionSpawnBinding.exact);
      expect(r.isPlausibleOwnership, isTrue);
    });

    test('wrapper spawn with dart session child', () async {
      final r = await verifyRunnerSessionSpawnBindingPids(
        discoveryPid: 4382,
        spawnPid: 4365,
        probe: const _FixedTreeProbe({4365: 1, 4382: 4365}),
      );
      expect(r.binding, RunnerSessionSpawnBinding.spawnAncestorsSessionOwner);
      expect(r.isPlausibleOwnership, isTrue);
    });

    test('unrelated pids', () async {
      final r = await verifyRunnerSessionSpawnBindingPids(
        discoveryPid: 200,
        spawnPid: 300,
        probe: const _FixedTreeProbe({200: 1, 300: 2}),
      );
      expect(r.binding, RunnerSessionSpawnBinding.unrelated);
      expect(r.isPlausibleOwnership, isFalse);
    });
  });
}
