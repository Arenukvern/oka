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

/// A tiny static file server — the web-shaped fetch evidence (ADR-0037
/// §5: the channel is host-agnostic; here the same tree is served over
/// HTTP and read as files, and the client cannot tell the difference).
Future<(HttpServer, String)> _serve(String root) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final file = File('$root${request.uri.path}');
    if (!file.existsSync()) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    request.response.add(file.readAsBytesSync());
    await request.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}');
}

void main() {
  late Directory tmp;
  late String root;
  late String channelDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-client-test-');
    root = '${tmp.path}/app';
    channelDir = '${tmp.path}/channel';
    Directory('$root/lib/units').createSync(recursive: true);
    File('$root/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
    File('$root/lib/units/feature.dart').writeAsStringSync(featureV1);
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<DeltaArtifact> fakeCompile(DeltaRequest request) async {
    final file = File('${tmp.path}/${request.unit}-${request.revision}.dill');
    file.writeAsStringSync('delta:${request.unit}@${request.revision}');
    return DeltaArtifact(path: file.path, bytes: file.lengthSync());
  }

  test('publish two revisions over file and HTTP; client chains; tamper fails',
      () async {
    // Baseline.
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'base-rev');
    // Patch revision.
    File('$root/lib/units/feature.dart').writeAsStringSync(featureV2);
    final ship = await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'rev2',
        compile: fakeCompile);
    expect(ship.mode, 'patch');

    const local = LocalInstall(baseline: 'base-rev');
    const client = UpdateClient();

    // File source.
    final fileSource = FileChannelSource(channelDir);
    final plan = await client.check(fileSource, local);
    expect(plan.mode, ChannelPlanMode.chain);
    final receipt = await client.apply(fileSource, local,
        stageDir: '${tmp.path}/stage-file');
    expect(receipt.ok, isTrue);
    expect(receipt.mode, 'chain');
    expect(receipt.stagedFiles.single, endsWith('feature-rev2.delta.dill'));
    expect(
        sha256File(receipt.stagedFiles.single),
        ship.deltas.single.artifact.sha256);

    // HTTP source — same tree, same verdicts.
    final (server, baseUrl) = await _serve(channelDir);
    try {
      final httpSource = HttpChannelSource(baseUrl: baseUrl);
      final httpPlan = await client.check(httpSource, local);
      expect(httpPlan.mode, ChannelPlanMode.chain);
      final httpReceipt = await client.apply(httpSource, local,
          stageDir: '${tmp.path}/stage-http');
      expect(httpReceipt.ok, isTrue);
      expect(httpReceipt.stagedFiles.single, endsWith('.delta.dill'));
    } finally {
      await server.close(force: true);
    }

    // Tamper with the artifact: digest verification must fail the
    // receipt, never stage silent corruption.
    final artifact =
        File('$channelDir/artifacts/feature-rev2.delta.dill');
    artifact.writeAsStringSync('tampered');
    final tampered = await client.apply(fileSource, local,
        stageDir: '${tmp.path}/stage-tamper');
    expect(tampered.ok, isFalse);
    expect(tampered.mode, 'failed');
    expect(tampered.reasons.join(' '), contains('sha256 mismatch'));
  });

  test('snapshot lane serves clients the chain cannot', () async {
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'base-rev');
    final snapshot = File('${tmp.path}/snap.zip')
      ..writeAsStringSync('whole-revision-aot-set');
    File('$root/lib/units/feature.dart').writeAsStringSync(featureV2);
    final ship = await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'rev2',
        compile: fakeCompile,
        snapshotFile: snapshot.path);
    expect(ship.snapshot, isNotNull);

    const client = UpdateClient();
    final receipt = await client.apply(
        FileChannelSource(channelDir),
        const LocalInstall(baseline: 'base-rev'),
        stageDir: '${tmp.path}/stage-snap',
        slotBudget: 0);
    expect(receipt.mode, 'snapshot',
        reason: 'slot budget 0 forces the snapshot lane');
    expect(receipt.snapshotPath, isNotNull);
    expect(receipt.ok, isTrue);
  });

  test('staged artifacts feed the AOT apply seam (android/linux/macOS)',
      () async {
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'base-rev');
    File('$root/lib/units/feature.dart').writeAsStringSync(featureV2);
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'rev2',
        compile: fakeCompile);

    final stageDir = '${tmp.path}/stage-aot';
    const client = UpdateClient();
    final receipt = await client.apply(
        FileChannelSource(channelDir),
        const LocalInstall(baseline: 'base-rev'),
        stageDir: stageDir);
    expect(receipt.ok, isTrue);

    // The staged artifact is a valid unit artifact for the staged lane:
    // a dummy base beside it, and StagedTarget reports the honest mode.
    File('$stageDir/app.so').writeAsStringSync('fake-base-snapshot');
    final target = StagedTarget(
        id: 'aot-target',
        artifactsDir: stageDir,
        baseArtifact: 'app.so',
        unitArtifact: receipt.stagedFiles.single);
    await target.connect();
    final outcome = await target.apply(
        unit: 'feature',
        deltaPath: receipt.stagedFiles.single,
        deltaBytes: File(receipt.stagedFiles.single).lengthSync());
    expect(outcome.ok, isTrue);
    expect(outcome.mode, 'staged-next-launch');
    expect(File('$stageDir/app.so-feature.part.so').existsSync(), isTrue);
  });

  test('unsigned pointer refuses when policy requires a signature',
      () async {
    await shipRevision(
        root: root,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: 'base-rev');
    // Flip the policy to require signatures (G-AC5 lands verification).
    final pointerFile = File('$channelDir/pointer.json');
    final pointer = ChannelPointer.fromJson(
        (jsonDecode(pointerFile.readAsStringSync()) as Map)
            .cast<String, dynamic>());
    pointerFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(
        ChannelPointer(
                channel: pointer.channel,
                revision: pointer.revision,
                policy: const ChannelPolicy(requiresSignature: true))
            .toJson()));

    const client = UpdateClient();
    final plan = await client.check(
        FileChannelSource(channelDir),
        const LocalInstall(baseline: 'base-rev'));
    expect(plan.mode, ChannelPlanMode.refused);
    expect(plan.reasons.join(' '), contains('unsigned'));
  });
}
