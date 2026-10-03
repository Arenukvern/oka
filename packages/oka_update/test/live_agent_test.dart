/// Behavior tests for the declared agent surface (ADR-0036 Tier 2):
/// the catalog is pure data serving the UA descriptor shape, dispatch
/// runs the real session paths, and every verb returns receipt JSON —
/// with in-memory targets, no real wires.
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';
import 'package:universal_automation_interface/universal_automation_interface.dart';

import 'live_session_test.dart' show FakeTarget;

// ignore_for_file: strict_raw_type, prefer_const_constructors, cast_nullable_to_non_nullable, unnecessary_lambdas

class _FakeHost implements LiveVerbHost {
  _FakeHost(this.root, this.target);
  @override
  final String root;
  final FakeTarget target;
  @override
  UnitDeltaCompiler get compile =>
      (request) async => DeltaArtifact(path: 'fake.delta.dill', bytes: 7);
  @override
  Map<String, LivePatchTarget> get targetOverrides => {'t1': target};
  @override
  void Function(LivePatchEvent event)? get onEvent => null;
}

Future<(LivePatchSpec, String)> _spec() async {
  final root = await Directory.systemTemp.createTemp('oka_agent_test');
  File('${root.path}/unit.dart').writeAsStringSync("const label = 'x';\n");
  const spec = LivePatchSpec(
    revision: 'rev-b',
    unit: 'alpha',
    patches: [
      PatchEdit(file: 'unit.dart', find: 'x', replace: 'y'),
    ],
    targets: [TargetSpec(kind: 'fake', id: 't1')],
    probes: [ProbeSpec(expression: 'label')],
  );
  return (spec, root.path);
}

void main() {
  test('catalog: three dotted verbs, descriptor shape, unique names', () {
    final names = liveVerbCatalog.map((v) => v.name).toList();
    expect(names,
        ['oka.live.patch', 'oka.live.watch', 'oka.live.verify']);
    for (final d in liveVerbDescriptors) {
      expect(d.name, isNotEmpty);
      expect(d.name.contains('.'), isTrue);
      expect(d.description, isNotEmpty);
      expect(d.inputSchema, isA<Map<String, Object?>>());
      // Round-trips through the UA contract's own decoder.
      expect(
        SurfaceActionDescriptor.fromJson(d.toJson())?.name,
        d.name,
      );
    }
  });

  test('runLiveVerb: unknown name throws with the known set', () async {
    final (spec, root) = await _spec();
    final host = _FakeHost(root, FakeTarget('t1'));
    expect(
      () => runLiveVerb('oka.live.nope', {'spec': spec.toJson()}, host),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('oka.live.patch: dispatches runLivePatch, receipt JSON out', () async {
    final (spec, root) = await _spec();
    final fake = FakeTarget('t1', applyValues: {'label': 'alpha-g4b'});
    final out = await runLiveVerb(
        'oka.live.patch', {'spec': spec.toJson()}, _FakeHost(root, fake));
    expect(out['ok'], isTrue);
    expect(out['revision'], 'rev-b');
    final targets = out['targets'] as List;
    expect((targets.single as Map)['mode'], 'fake-apply');
    expect(fake.applied, 1);
  });

  test('oka.live.verify: probes captured, no patch applied', () async {
    final (spec, root) = await _spec();
    final fake = FakeTarget('t1');
    final out = await runLiveVerb(
        'oka.live.verify', {'spec': spec.toJson()}, _FakeHost(root, fake));
    expect(out['ok'], isTrue);
    expect(fake.applied, 0);
    final probes = ((out['targets'] as List).single as Map)['probes'] as List;
    expect((probes.single as Map)['before'], 'alpha-g4a');
  });

  test('oka.live.verify: unreachable target fails the receipt', () async {
    final (spec, root) = await _spec();
    final out = await runLiveVerb('oka.live.verify',
        {'spec': spec.toJson()}, _FakeHost(root, FakeTarget('t1', failConnect: true)));
    expect(out['ok'], isFalse);
    expect(out['refusal'] ?? ((out['targets'] as List).single as Map)['refusal'],
        isNotNull);
  });

  test('oka.live.watch: applyChange path returns the receipt', () async {
    final (spec, root) = await _spec();
    final fake = FakeTarget('t1', applyValues: {'label': 'alpha-g4b'});
    final out = await runLiveVerb('oka.live.watch', {
      'spec': spec.toJson(),
      'changedFile': '$root/unit.dart',
    }, _FakeHost(root, fake));
    expect(out['ok'], isTrue);
    expect(fake.applied, 1);
  });
}
