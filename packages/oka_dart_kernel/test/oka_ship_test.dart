import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

import '../tool/oka_ship.dart' show runShipCli;

void main() {
  late Directory tmp;
  late String root;
  late String channelDir;
  var revision = 'base-rev';
  var exitCode = 0;
  final lines = <String>[];

  Future<DeltaArtifact> fakeCompile(DeltaRequest request) async {
    final file = File('${tmp.path}/${request.unit}-${request.revision}.dill');
    file.writeAsStringSync('delta:${request.unit}@${request.revision}');
    return DeltaArtifact(path: file.path, bytes: file.lengthSync());
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-ship-cli-test-');
    root = '${tmp.path}/app';
    channelDir = '${tmp.path}/channel';
    Directory('$root/lib/units').createSync(recursive: true);
    File('$root/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
    File('$root/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 1;\n}\n');
    revision = 'base-rev';
    exitCode = 0;
    lines.clear();
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<void> ship(List<String> args) => runShipCli(
        ['--project', root, '--channel-dir', channelDir, ...args],
        compiler: fakeCompile,
        unitsProvider: (project) async => const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        revisionProvider: (project) => revision,
        output: lines.add,
        errorOutput: lines.add,
        setExitCode: (c) => exitCode = c,
      );

  test('baseline then body-only patch: zero flags, receipts all the way',
      () async {
    await ship([]);
    expect(exitCode, 0);
    expect(File('$channelDir/pointer.json').existsSync(), isTrue);
    expect(lines.join('\n'), contains('baseline'));

    lines.clear();
    revision = 'rev2';
    File('$root/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    await ship([]);
    expect(exitCode, 0);
    expect(lines.join('\n'), contains('patch'));
    expect(
        File('$channelDir/artifacts/feature-rev2.delta.dill').existsSync(),
        isTrue);
    // The receipt names the unit and the changed file (one line per
    // derivation — ADR-0037 §1).
    final receipt = lines.join('\n');
    expect(receipt, contains('feature'));
    expect(receipt, contains('lib/units/feature.dart'));
  });

  test('dry-run derives but publishes nothing', () async {
    await ship([]);
    lines.clear();
    revision = 'rev2';
    File('$root/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    await ship(['--dry-run']);
    expect(exitCode, 0);
    expect(
        File('$channelDir/artifacts/feature-rev2.delta.dill').existsSync(),
        isFalse);
  });

  test('contract-touching edit refuses with exit 1', () async {
    await ship([]);
    lines.clear();
    revision = 'rev3';
    File('$root/lib/units/feature.dart').writeAsStringSync('''
class FeatureNew {
  const FeatureNew();
}

int featureValue() {
  return 1;
}
''');
    await ship([]);
    expect(exitCode, 1);
    expect(lines.join('\n'), contains('REFUSED'));
  });

  test('unknown token prints usage with exit 2', () async {
    await ship(['--bogus']);
    expect(exitCode, 2);
    expect(lines.join('\n'), contains('usage: oka ship'));
  });

  test('explicit --revision works without git (regression: it was '
      'ignored)', () async {
    // No revisionProvider injected: the runner must use --revision, not
    // demand a git checkout.
    final exit = <int>[];
    await runShipCli(
      [
        '--project', root,
        '--channel-dir', channelDir,
        '--revision', 'flag-rev',
      ],
      compiler: fakeCompile,
      unitsProvider: (project) async => const [
        PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
      ],
      output: lines.add,
      errorOutput: lines.add,
      setExitCode: exit.add,
    );
    expect(exit.single, 0);
    expect(File('$channelDir/manifests/flag-rev.json').existsSync(), isTrue);
  });

  test('--snapshot-from-build <file> attaches the whole-revision artifact',
      () async {
    final build = File('${tmp.path}/main.dart.js')
      ..writeAsStringSync('whole web bundle');
    await ship(['--snapshot-from-build', build.path]);
    expect(exitCode, 0);
    final node = RevisionNode.fromJson((jsonDecode(
            File('$channelDir/manifests/base-rev.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());
    expect(node.snapshot, isNotNull);
    expect(node.snapshot!.file, 'artifacts/base-rev.snapshot.js');
  });

  test('--snapshot-from-build <dir> archives the build output', () async {
    final buildDir = Directory('${tmp.path}/web-build')..createSync();
    File('${buildDir.path}/index.html').writeAsStringSync('<html></html>');
    await ship(['--snapshot-from-build', buildDir.path]);
    expect(exitCode, 0);
    final node = RevisionNode.fromJson((jsonDecode(
            File('$channelDir/manifests/base-rev.json').readAsStringSync())
        as Map)
        .cast<String, dynamic>());
    expect(node.snapshot!.file, 'artifacts/base-rev.snapshot.tgz');
    final staged = File('$channelDir/${node.snapshot!.file}');
    expect(staged.existsSync(), isTrue);
    expect(staged.lengthSync(), greaterThan(0));
  });

  test('--max-chain-bytes seeds the pointer policy (publisher override)',
      () async {
    await ship(['--max-chain-bytes', '4096', '--max-chain-revisions', '2']);
    expect(exitCode, 0);
    final pointer = ChannelPointer.fromJson((jsonDecode(
            File('$channelDir/pointer.json').readAsStringSync()) as Map)
        .cast<String, dynamic>());
    expect(pointer.policy.maxChainBytes, 4096);
    expect(pointer.policy.maxChainRevisions, 2);
  });
}
