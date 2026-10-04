import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

UpdateReceipt receipt(List<String> staged, String revision) => UpdateReceipt(
    ok: true, mode: 'chain', fromRevision: 'base', toRevision: revision,
    steps: [
      for (final f in staged)
        ApplyStep(
            revision: revision,
            unit: 'engine',
            artifact: UnitArtifact(
                file: f, sha256: 'sha-$f', bytes: 1),
            status: 'applied',
            stagedPath: f),
    ]);

void main() {
  late Directory tmp;
  late String root;
  late String a;
  late String b;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-journal-test-');
    root = '${tmp.path}/updates';
    a = '${tmp.path}/a.delta.dill';
    b = '${tmp.path}/b.delta.dill';
    File(a).writeAsStringSync('artifact-a');
    File(b).writeAsStringSync('artifact-b');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('stage -> commit promotes the staged set to current', () {
    final journal = StagedUpdateJournal(root);
    expect(journal.read().current, isNull, reason: 'fresh install');

    journal.stage(receipt([a, b], 'rev2'));
    final staged = journal.read();
    expect(staged.staged, 'staged');
    expect(staged.revision, 'rev2');
    expect(File('$root/staged/a.delta.dill').existsSync(), isTrue);

    // The beacon fired: promote.
    final committed = journal.commit();
    expect(committed.staged, isNull);
    expect(committed.current, 'current');
    expect(File('$root/current/a.delta.dill').existsSync(), isTrue);
    expect(Directory('$root/staged').existsSync(), isFalse,
        reason: 'staged was renamed, not copied');
  });

  test('stage -> rollback keeps the known-good set (never bricks)', () {
    final journal = StagedUpdateJournal(root);
    journal.stage(receipt([a], 'rev1'));
    journal.commit();
    final knownGood = File('$root/current/a.delta.dill').readAsStringSync();

    // A bad candidate is staged, then the beacon never fires.
    journal.stage(receipt([b], 'rev2-bad'));
    expect(File('$root/staged/b.delta.dill').existsSync(), isTrue);

    journal.rollback();
    expect(Directory('$root/staged').existsSync(), isFalse);
    expect(journal.read().staged, isNull);
    expect(File('$root/current/a.delta.dill').readAsStringSync(),
        knownGood, reason: 'current untouched by rollback');
  });

  test('rollback on a fresh install leaves nothing staged, nothing current',
      () {
    final journal = StagedUpdateJournal(root);
    journal.stage(receipt([a], 'rev1'));
    journal.rollback();
    final state = journal.read();
    expect(state.staged, isNull);
    expect(state.current, isNull,
        reason: 'nothing was ever promoted — the fresh install just boots '
            'its own binary, as before');
  });

  test('UpdateClient.apply with a journal stages the boot-watchdog set',
      () async {
    // Publish a channel: baseline + one patch.
    final appRoot = '${tmp.path}/app';
    Directory('$appRoot/lib/units').createSync(recursive: true);
    File('$appRoot/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 1;\n}\n');
    const units = [
      PatchUnit(name: 'engine', libraries: ['lib/units/feature.dart']),
    ];
    final channelDir = '${tmp.path}/channel';
    Future<DeltaArtifact> compile(DeltaRequest r) async {
      final f = File('${tmp.path}/${r.unit}-${r.revision}.dill');
      f.writeAsStringSync('delta:${r.unit}@${r.revision}');
      return DeltaArtifact(path: f.path, bytes: f.lengthSync());
    }

    await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'base-rev');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'rev2', compile: compile);

    final journal = StagedUpdateJournal('${tmp.path}/updates');
    const client = UpdateClient();
    final receipt = await client.apply(
        FileChannelSource(channelDir),
        const LocalInstall(baseline: 'base-rev'),
        stageDir: '${tmp.path}/stage',
        journal: journal);
    expect(receipt.ok, isTrue);
    expect(receipt.journal, isNotNull);
    expect(receipt.journal!.staged, 'staged');
    expect(receipt.journal!.revision, 'rev2');
    expect(
        File('${tmp.path}/updates/staged/engine-rev2.delta.dill')
            .existsSync(),
        isTrue);
    expect(receipt.toJson()['journal'], isNotNull,
        reason: 'the journal state rides the receipt JSON');

    // The beacon fires: commit promotes the set.
    journal.commit();
    expect(
        File('${tmp.path}/updates/current/engine-rev2.delta.dill')
            .existsSync(),
        isTrue);
  });

  test('a corrupt journal reads dirty instead of crashing', () {
    final journal = StagedUpdateJournal(root);
    Directory(root).createSync(recursive: true);
    File('$root/journal.json').writeAsStringSync('{not json');
    final state = journal.read();
    expect(state.dirty, isTrue);
    // Rollback recovers to a clean journal.
    final recovered = journal.rollback();
    expect(recovered.dirty, isFalse);
  });
}
