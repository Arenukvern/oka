import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

const featureV1 = '''
int featureValue() {
  return 1;
}
''';

const featureV2 = '''
int featureValue() {
  return 2;
}
''';

const featureV3 = '''
int featureValue() {
  return 3;
}
''';

const featureV3Contract = '''
class FeatureContract {
  const FeatureContract();
}

int featureValue() {
  return 2;
}
''';

/// Builds a fixture app root: lib/core.dart + lib/units/feature.dart.
String _app(Directory tmp, String feature) {
  final root = '${tmp.path}/app';
  Directory('$root/lib/units').createSync(recursive: true);
  File('$root/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
  File('$root/lib/units/feature.dart').writeAsStringSync('$feature\n');
  return root;
}

final _units = [
  const PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
];

/// Fake compiler: writes a deterministic artifact naming the unit+rev.
Future<DeltaArtifact> fakeCompile(DeltaRequest request) async {
  final file =
      File('${Directory.systemTemp.path}/'
          '${request.unit}-${request.revision}.fake.dill');
  file.writeAsStringSync('delta:${request.unit}@${request.revision}');
  return DeltaArtifact(path: file.path, bytes: file.lengthSync());
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-ship-test-');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('fresh channel seeds a baseline; dirty trees refuse', () async {
    final root = _app(tmp, featureV1);
    final receipt = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    expect(receipt.ok, isTrue);
    expect(receipt.mode, 'baseline');
    expect(receipt.baseline, 'base-rev');
    expect(File('${tmp.path}/channel/pointer.json').existsSync(), isTrue);
    expect(
        File('${tmp.path}/channel/manifests/base-rev.json').existsSync(),
        isTrue);

    // A second baseline ship with the same content: nothing changed.
    final again = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'rev2');
    expect(again.mode, 'nothing-to-ship');
  });

  test('body-only edit derives a patch with no hand-written patch code',
      () async {
    final root = _app(tmp, featureV1);
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV2\n');

    final receipt = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'rev2',
        compile: fakeCompile);
    expect(receipt.ok, isTrue);
    expect(receipt.mode, 'patch');
    expect(receipt.plan!.changedUnits, ['feature']);
    expect(receipt.deltas.single.changedFiles,
        ['lib/units/feature.dart']);
    final artifact = File(
        '${tmp.path}/channel/artifacts/feature-rev2.delta.dill');
    expect(artifact.existsSync(), isTrue);
    expect(receipt.deltas.single.artifact.sha256,
        sha256File(artifact.path));
  });

  test('contract-touching edit refuses with the store alternative',
      () async {
    final root = _app(tmp, featureV2);
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    File('$root/lib/units/feature.dart')
        .writeAsStringSync('$featureV3Contract\n');

    final receipt = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'rev3',
        compile: fakeCompile);
    expect(receipt.ok, isFalse);
    expect(receipt.mode, 'refused');
    expect(receipt.reasons.join(' '), contains('store lane'));
  });

  test('core edit is recorded (coreChanged) and patchable', () async {
    final root = _app(tmp, featureV1);
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    File('$root/lib/core.dart').writeAsStringSync('int coreSeed() => 8;\n');

    final receipt = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'rev2',
        compile: fakeCompile);
    expect(receipt.ok, isTrue);
    expect(receipt.plan!.coreChanged, isTrue);
    expect(receipt.deltas, isEmpty,
        reason: 'no unit changed — core retransfer is the recorded cost');
  });

  test('dry-run derives everything and publishes nothing', () async {
    final root = _app(tmp, featureV1);
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV2\n');

    final receipt = await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'rev2',
        dryRun: true,
        compile: fakeCompile);
    expect(receipt.mode, 'dry-run');
    expect(receipt.deltas.single.unit, 'feature');
    expect(
        File('${tmp.path}/channel/artifacts/feature-rev2.delta.dill')
            .existsSync(),
        isFalse);
    final pointer =
        File('${tmp.path}/channel/pointer.json').readAsStringSync();
    expect(pointer, contains('base-rev'),
        reason: 'pointer must still pin the baseline');
  });

  test('snapshot artifact rides the node and the pointer moves', () async {
    final root = _app(tmp, featureV1);
    final snapshot = File('${tmp.path}/snapshot.zip')
      ..writeAsStringSync('fake-aot-set');
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev',
        snapshotFile: snapshot.path);
    final node = RevisionNode.fromJson((jsonDecode(
            File('${tmp.path}/channel/manifests/base-rev.json')
                .readAsStringSync()) as Map)
        .cast<String, dynamic>());
    expect(node.snapshot!.file, 'artifacts/base-rev.snapshot.zip');
    final pointer = ChannelPointer.fromJson((jsonDecode(
            File('${tmp.path}/channel/pointer.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());
    expect(pointer.revision, 'base-rev');
  });

  test('chainLoad projects the bytes and revisions a client must apply',
      () async {
    final root = _app(tmp, featureV1);
    final channelDir = '${tmp.path}/channel';
    await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'base');
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV2\n');
    await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'r2', compile: fakeCompile);
    final head = RevisionNode.fromJson((jsonDecode(
            File('$channelDir/manifests/r2.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());

    // A client at the baseline applies r2 only: one revision, its bytes.
    final fresh = chainLoad(channelDir, head, head.baseline);
    expect(fresh.revisions, 1);
    expect(fresh.bytes, greaterThan(0));

    // A client already at head applies nothing.
    final current = chainLoad(channelDir, head, head.revision);
    expect(current.revisions, 0);
    expect(current.bytes, 0);
  });

  test('chain overrun derives a snapshot from the build pipeline '
      '(G-AC6)', () async {
    final root = _app(tmp, featureV1);
    final channelDir = '${tmp.path}/channel';
    // A policy of 1 byte forces the snapshot lane on the first patch.
    await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'base', policy: const ChannelPolicy(maxChainBytes: 1));
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV2\n');

    var builds = 0;
    final receipt = await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'r2', compile: fakeCompile, snapshotBuilder: () async {
      builds++;
      final f = File('${tmp.path}/whole-revision.dill')
        ..writeAsStringSync('full-kernel');
      return f.path;
    });
    expect(receipt.ok, isTrue, reason: receipt.reasons.join('; '));
    expect(builds, 1, reason: 'the trigger must derive exactly once');
    expect(receipt.snapshot, isNotNull);
    expect(receipt.reasons.join(' '), contains('snapshot derived'));
    final node = RevisionNode.fromJson((jsonDecode(
            File('$channelDir/manifests/r2.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());
    expect(node.snapshot!.file, 'artifacts/r2.snapshot.dill');
    expect(node.snapshot!.sha256,
        sha256File('$channelDir/${node.snapshot!.file}'));
  });

  test('no derivation under policy, and no trigger without a builder',
      () async {
    final root = _app(tmp, featureV1);
    final channelDir = '${tmp.path}/channel';
    await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'base');
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV2\n');

    var builds = 0;
    final withBuilder = await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'r2', compile: fakeCompile, snapshotBuilder: () async {
      builds++;
      return '${tmp.path}/never.dill';
    });
    expect(withBuilder.ok, isTrue);
    expect(builds, 0, reason: 'policy not overrun — no snapshot build');
    expect(withBuilder.snapshot, isNull);

    // A second revision with the builder removed still ships (the
    // client-side refusal names the fix, ship stays usable).
    File('$root/lib/units/feature.dart').writeAsStringSync('$featureV3\n');
    final withoutBuilder = await shipRevision(
        root: root, units: _units, channelDir: channelDir,
        revision: 'r3', compile: fakeCompile);
    expect(withoutBuilder.ok, isTrue);
  });

  test('publisher policy seeds the baseline pointer', () async {
    final root = _app(tmp, featureV1);
    await shipRevision(
        root: root,
        units: _units,
        channelDir: '${tmp.path}/channel',
        revision: 'base',
        policy: const ChannelPolicy(maxChainRevisions: 2));
    final pointer = ChannelPointer.fromJson((jsonDecode(
            File('${tmp.path}/channel/pointer.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());
    expect(pointer.policy.maxChainRevisions, 2);
  });

  test('workspace-package units derive across packages (real-app shape)',
      () async {
    // packages/engine/lib/src/fractional.dart is the declared unit; its
    // package sibling core.dart is core. Root lib/ also scanned.
    final root = '${tmp.path}/wsapp';
    Directory('$root/lib').createSync(recursive: true);
    Directory('$root/packages/engine/lib/src').createSync(recursive: true);
    File('$root/lib/main.dart').writeAsStringSync('void main() {}\n');
    File('$root/packages/engine/lib/src/fractional.dart')
        .writeAsStringSync('String orderLabel() {\n  return "b";\n}\n');
    File('$root/packages/engine/lib/src/engine_core.dart')
        .writeAsStringSync('int engineSeed() => 1;\n');

    Future<ShipReceipt> shipWith(String fractionalBody, String rev,
            {UnitDeltaCompiler? compile}) =>
        shipRevision(
            root: root,
            units: const [
              PatchUnit(
                  name: 'engine',
                  libraries: [
                    'packages/engine/lib/src/fractional.dart',
                  ]),
            ],
            channelDir: '${tmp.path}/wschannel',
            revision: rev,
            compile: compile);

    final baseline = await shipWith('return "b";', 'ws-base');
    expect(baseline.mode, 'baseline');

    File('$root/packages/engine/lib/src/fractional.dart')
        .writeAsStringSync('String orderLabel() {\n  return "c";\n}\n');
    final patch = await shipWith('return "c";', 'ws-r2', compile: fakeCompile);
    expect(patch.ok, isTrue, reason: patch.reasons.join('; '));
    expect(patch.mode, 'patch');
    expect(patch.deltas.single.changedFiles,
        ['packages/engine/lib/src/fractional.dart']);

    // The package sibling is core: editing it moves the core fingerprint.
    File('$root/packages/engine/lib/src/engine_core.dart')
        .writeAsStringSync('int engineSeed() => 2;\n');
    final coreEdit = await shipWith('return "c";', 'ws-r3', compile: fakeCompile);
    expect(coreEdit.plan!.coreChanged, isTrue);
  });

  test('a unit with several changed files refuses (one seam per revision)',
      () async {
    // Both edits must be body-only (fingerprints stable) so the refusal
    // comes from the seam rule, not from a contract verdict.
    final root = '${tmp.path}/multi';
    Directory('$root/lib/units').createSync(recursive: true);
    File('$root/lib/units/a.dart')
        .writeAsStringSync('int a() {\n  return 1;\n}\n');
    File('$root/lib/units/b.dart')
        .writeAsStringSync('int b() {\n  return 1;\n}\n');
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'multi', libraries: [
            'lib/units/a.dart',
            'lib/units/b.dart',
          ]),
        ],
        channelDir: '${tmp.path}/channel',
        revision: 'base-rev');
    File('$root/lib/units/a.dart')
        .writeAsStringSync('int a() {\n  return 2;\n}\n');
    File('$root/lib/units/b.dart')
        .writeAsStringSync('int b() {\n  return 2;\n}\n');

    final receipt = await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'multi', libraries: [
            'lib/units/a.dart',
            'lib/units/b.dart',
          ]),
        ],
        channelDir: '${tmp.path}/channel',
        revision: 'r2',
        compile: fakeCompile);
    expect(receipt.ok, isFalse);
    expect(receipt.mode, 'refused');
    expect(receipt.reasons.join(' '), contains('one seam per revision'));
  });
}
