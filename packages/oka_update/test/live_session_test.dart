/// Behavior tests for the live patch session: the event ladder, probe
/// semantics (expect flips, hold proves no restart), refusal paths, and
/// receipt/describe output — with in-memory targets, no real wires.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

/// Simulates a program: probe values keyed by expression; `apply` flips
/// the value of expressions listed in [flips] and leaves everything else
/// (so `hold` probes see an identical value).
class FakeTarget implements LivePatchTarget {
  FakeTarget(
    this.id, {
    this.failApply = false,
    this.failConnect = false,
    Map<String, String> initialValues = const {},
    this.applyValues = const {},
  }) : values = {
          'label': 'alpha-g4a',
          'state': 'boot',
          ...initialValues,
        };

  @override
  final String id;
  @override
  final String kind = 'fake';

  final bool failApply;
  final bool failConnect;
  final Map<String, String> values;

  /// Values to flip when a patch applies (simulating the reload).
  final Map<String, String> applyValues;
  int applied = 0;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('no program there');
  }

  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async {
    if (failApply) {
      return const ApplyOutcome(ok: false, mode: 'fake', error: 'wire said no');
    }
    applied++;
    values
      ..['label'] = 'alpha-g4b'
      ..addAll(applyValues);
    return ApplyOutcome(ok: true, mode: 'fake-apply', wire: {'bytes': deltaBytes});
  }

  @override
  Future<ApplyOutcome> syncAsset(
          {required String assetKey,
          required List<int> bytes,
          required String flutterAssetsDir,
          bool shader = false}) async =>
      const ApplyOutcome(
          ok: false, mode: 'assets-sync', error: 'fake: unsupported');

  @override
  Future<String> evaluate(ProbeSpec probe) async => values[probe.expression]!;

  @override
  Future<void> close() async {}
}

Future<(LivePatchSpec, String)> _writeSpec() async {
  final root = await Directory.systemTemp.createTemp('oka_live_test');
  File('${root.path}/unit.dart')
      .writeAsStringSync("const label = 'alpha-g4a';\n");
  const spec = LivePatchSpec(
    revision: 'rev-b',
    unit: 'alpha',
    patches: [
      PatchEdit(
          file: 'unit.dart',
          find: "const label = 'alpha-g4a';",
          replace: "const label = 'alpha-g4b';"),
    ],
    targets: [
      TargetSpec(kind: 'fake', id: 't1'),
    ],
    probes: [
      ProbeSpec(expression: 'label', expect: 'alpha-g4b'),
      ProbeSpec(expression: 'state', hold: true),
    ],
  );
  return (spec, root.path);
}

void main() {
  watcherTests();
  test('session: apply, verify, receipt, restore', () async {
    final (spec, root) = await _writeSpec();
    final fake = FakeTarget('t1');
    final session = LivePatchSession(
      spec: spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(List.filled(11, 1));
        return DeltaArtifact(path: f.path, bytes: 11);
      },
      targetOverrides: {'t1': fake},
    );

    final events = <LivePatchEvent>[];
    final session2 = LivePatchSession(
      spec: spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(List.filled(11, 1));
        return DeltaArtifact(path: f.path, bytes: 11);
      },
      targetOverrides: {'t1': fake},
      onEvent: events.add,
    );
    final receipt = await session2.run();

    expect(receipt.ok, isTrue, reason: receipt.describe());
    expect(receipt.targets.single.mode, 'fake-apply');
    expect(receipt.targets.single.deltaBytes, 11);
    expect(receipt.targets.single.probes.map((p) => p.ok), everyElement(isTrue));
    expect(receipt.targets.single.probes.last.held, isTrue,
        reason: 'hold probe must prove no restart');

    expect(
      events.map((e) => e.phase),
      containsAll(<LivePatchPhase>[
        LivePatchPhase.planned,
        LivePatchPhase.connected,
        LivePatchPhase.patched,
        LivePatchPhase.compiled,
        LivePatchPhase.applying,
        LivePatchPhase.applied,
        LivePatchPhase.verified,
      ]),
    );

    // The source edit happened on disk; restore() reverts it.
    expect(File('$root/unit.dart').readAsStringSync(), contains('alpha-g4b'));
    await session.restore();
    expect(File('$root/unit.dart').readAsStringSync(), contains('alpha-g4a'));
    await Directory(root).delete(recursive: true);
  });

  test('session: JSON spec round-trip and load', () async {
    final (spec, root) = await _writeSpec();
    final dir = await Directory.systemTemp.createTemp('oka_live_spec');
    final path = '${dir.path}/live_patch.json';
    await File(path).writeAsString(jsonEncode(spec.toJson()));
    final loaded = await LivePatchSpec.load(path);
    expect(loaded.unit, spec.unit);
    expect(loaded.patches.single.file, spec.patches.single.file);
    expect(loaded.targets.single.id, 't1');
    expect(loaded.probes.length, 2);
    await dir.delete(recursive: true);
    await Directory(root).delete(recursive: true);
  });

  test('session: missing marker refuses without touching targets', () async {
    final (spec, root) = await _writeSpec();
    final bad = LivePatchSpec(
      revision: 'rev-b',
      unit: 'alpha',
      patches: [
        const PatchEdit(file: 'unit.dart', find: 'not-there', replace: 'x'),
      ],
      targets: spec.targets,
      probes: spec.probes,
    );
    final fake = FakeTarget('t1');
    final session = LivePatchSession(
      spec: bad,
      root: root,
      compile: (request) async => throw StateError('must not compile'),
      targetOverrides: {'t1': fake},
    );
    final receipt = await session.run();
    expect(receipt.ok, isFalse);
    expect(receipt.refusal, contains('patch marker not found'));
    expect(fake.applied, 0);
    await Directory(root).delete(recursive: true);
  });

  test('session: failed apply lands in the receipt, other targets run',
      () async {
    final (spec, root) = await _writeSpec();
    final bad = FakeTarget('bad', failApply: true);
    final good = FakeTarget('good');
    final session = LivePatchSession(
      spec: spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(const [1]);
        return DeltaArtifact(path: f.path, bytes: 1);
      },
      targetOverrides: {'t1': bad, 't2': good},
    );
    // Rename the spec's single target to the two overrides by adding one.
    final two = LivePatchSpec(
      revision: spec.revision,
      unit: spec.unit,
      patches: spec.patches,
      targets: [
        const TargetSpec(kind: 'fake', id: 'bad'),
        const TargetSpec(kind: 'fake', id: 'good'),
      ],
      probes: spec.probes,
    );
    final session2 = LivePatchSession(
      spec: two,
      root: root,
      compile: session.compile,
      targetOverrides: {'bad': bad, 'good': good},
    );
    final receipt = await session2.run();
    expect(receipt.ok, isFalse);
    expect(receipt.targets.length, 2);
    expect(receipt.targets.first.ok, isFalse);
    expect(receipt.targets.last.ok, isTrue);
    expect(bad.applied, 0, reason: 'failed apply did not take');
    expect(good.applied, 1);
    await Directory(root).delete(recursive: true);
  });

  test('session: connect failure is a per-target refusal, not a crash',
      () async {
    final (spec, root) = await _writeSpec();
    final dead = FakeTarget('dead', failConnect: true);
    final session = LivePatchSession(
      spec: spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(const [1]);
        return DeltaArtifact(path: f.path, bytes: 1);
      },
      targetOverrides: {'t1': dead},
    );
    final receipt = await session.run();
    expect(receipt.ok, isFalse);
    expect(receipt.targets.single.refusal, contains('no program there'));
    // Patch still applied on disk; restore for cleanliness.
    await session.restore();
    await Directory(root).delete(recursive: true);
  });

  test('runLivePatch: one-call composition root', () async {
    final (spec, root) = await _writeSpec();
    final fake = FakeTarget('t1');
    final events = <LivePatchEvent>[];
    final receipt = await runLivePatch(
      spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(const [1]);
        return DeltaArtifact(path: f.path, bytes: 1);
      },
      targetOverrides: {'t1': fake},
      onEvent: events.add,
    );
    expect(receipt.ok, isTrue, reason: receipt.describe());
    expect(events.map((e) => e.phase), contains(LivePatchPhase.applied));
    await Directory(root).delete(recursive: true);
  });

  test('describe() renders the debug view', () async {
    final (spec, root) = await _writeSpec();
    final fake = FakeTarget('t1');
    final session = LivePatchSession(
      spec: spec,
      root: root,
      compile: (request) async {
        final f = File('${request.root}/alpha.delta.dill');
        f.writeAsBytesSync(const [1, 2, 3]);
        return DeltaArtifact(path: f.path, bytes: 3);
      },
      targetOverrides: {'t1': fake},
    );
    final receipt = await session.run();
    final text = receipt.describe();
    expect(text, contains('live patch OK'));
    expect(text, contains('t1 (fake) via fake-apply'));
    expect(text, contains('`label`: alpha-g4a -> alpha-g4b'));
    expect(text, contains('(held)'));
    await Directory(root).delete(recursive: true);
  });
}

void watcherTests() {
  test('LiveWatcher: save -> applyChange -> receipt, silent success',
      () async {
    final dir = await Directory.systemTemp.createTemp('oka_watcher_test');
    final unitFile = File('${dir.path}/lib/units/feature.dart')
      ..createSync(recursive: true);
    unitFile.writeAsStringSync("String feature() => 'v1';\n");

    final fake = FakeTarget('t1',
        initialValues: {'feature()': 'v1'},
        applyValues: {'feature()': 'v2'});
    final watcher = LiveWatcher(
      unit: 'feature',
      files: [unitFile.path],
      revision: 'dev',
      targets: [const TargetSpec(kind: 'fake', id: 't1')],
      probes: const [
        ProbeSpec(expression: 'feature()', expect: 'v2'),
      ],
      compile: (request) async {
        final f = File('${request.root}/feature.delta.dill');
        f.writeAsBytesSync(const [1]);
        return DeltaArtifact(path: f.path, bytes: 1);
      },
      root: dir.path,
      targetOverrides: {'t1': fake},
      debounce: const Duration(milliseconds: 50),
    );

    final done = Completer<LivePatchReceipt>();
    final sub = watcher.receipts.listen(done.complete);
    watcher.start();

    // The user saves an edit in their editor.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    unitFile.writeAsStringSync("String feature() => 'v2';\n");

    final receipt = await done.future.timeout(const Duration(seconds: 10));
    expect(receipt.ok, isTrue, reason: receipt.describe());
    expect(fake.applied, 1);
    await sub.cancel();
    await watcher.stop();
    await dir.delete(recursive: true);
  });
}
