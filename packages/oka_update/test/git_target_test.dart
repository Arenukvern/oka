import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String appRoot;
  late String channelDir;
  late String repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-git-target-test-');
    appRoot = '${tmp.path}/app';
    channelDir = '${tmp.path}/channel';
    repo = '${tmp.path}/origin';
    Directory('$appRoot/lib/units').createSync(recursive: true);
    File('$appRoot/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 1;\n}\n');
    // A stand-in "origin": a real local repo with one commit.
    _git(['init', '-b', 'main', repo]);
    File('$repo/README.md').writeAsStringSync('origin\n');
    _git(['add', '-A'], cwd: repo);
    _git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-m', 'init'],
        cwd: repo);
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<DeltaArtifact> fakeCompile(DeltaRequest request) async {
    final file = File('${tmp.path}/${request.unit}-${request.revision}.dill');
    file.writeAsStringSync('delta:${request.unit}@${request.revision}');
    return DeltaArtifact(path: file.path, bytes: file.lengthSync());
  }

  Future<ShipReceipt> ship(String revision) => shipRevision(
        root: appRoot,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: revision,
        compile: fakeCompile,
      );

  test('ship -> git branch -> client reads the checkout end to end',
      () async {
    await ship('base-rev');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    final patch = await ship('rev2');
    expect(patch.mode, 'patch');

    final published = await publishChannelToGit(
        channelDir: channelDir, repo: repo, branch: 'oka-channel');
    expect(published.ok, isTrue, reason: published.reasons.join('; '));
    expect(published.files, greaterThanOrEqualTo(2),
        reason: 'pointer + manifest + artifact');
    expect(published.commit, isNotNull);

    // The client side: a branch checkout is just a file tree.
    await checkoutChannelBranch(
        repo: repo, branch: 'oka-channel', into: '${tmp.path}/checkout');
    final source = FileChannelSource('${tmp.path}/checkout');
    const client = UpdateClient();
    final plan = await client.check(
        source, const LocalInstall(baseline: 'base-rev'));
    expect(plan.mode, ChannelPlanMode.chain);
    final receipt = await client.apply(source,
        const LocalInstall(baseline: 'base-rev'),
        stageDir: '${tmp.path}/stage');
    expect(receipt.ok, isTrue);
    expect(receipt.stagedFiles.single, endsWith('feature-rev2.delta.dill'));
  });

  test('republish replaces branch content atomically (orphan history)',
      () async {
    await ship('base-rev');
    final first = await publishChannelToGit(
        channelDir: channelDir, repo: repo, branch: 'oka-channel');
    expect(first.ok, isTrue);

    // The repo's main working tree must be untouched by publishing.
    expect(File('$repo/README.md').readAsStringSync(), 'origin\n');

    File('$channelDir/pointer.json').writeAsStringSync('{"x":1}\n');
    final second = await publishChannelToGit(
        channelDir: channelDir, repo: repo, branch: 'oka-channel');
    expect(second.ok, isTrue);
    expect(second.commit, isNot(first.commit));
  });

  test('bare origin works through the push lane', () async {
    final bare = '${tmp.path}/origin-bare.git';
    _git(['init', '-q', '--bare', '-b', 'main', bare]);
    _git(['push', '-q', bare, 'main'], cwd: repo);

    await ship('base-rev');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    final patch = await ship('rev2');
    expect(patch.mode, 'patch');

    final published = await publishChannelToGit(
        channelDir: channelDir, repo: bare, branch: 'oka-channel');
    expect(published.ok, isTrue, reason: published.reasons.join('; '));
    expect(published.commit, isNotNull);

    // The client reads the bare repo's branch straight (git archive works
    // on bare repos).
    await checkoutChannelBranch(
        repo: bare, branch: 'oka-channel', into: '${tmp.path}/checkout-bare');
    final receipt = await const UpdateClient().apply(
        FileChannelSource('${tmp.path}/checkout-bare'),
        const LocalInstall(baseline: 'base-rev'),
        stageDir: '${tmp.path}/stage-bare');
    expect(receipt.ok, isTrue);
    expect(receipt.stagedFiles.single, endsWith('feature-rev2.delta.dill'));
  });

  test('non-repo target refuses naming the fix', () async {
    await ship('base-rev');
    final published = await publishChannelToGit(
        channelDir: channelDir, repo: '${tmp.path}/not-a-repo', branch: 'b');
    expect(published.ok, isFalse);
    expect(published.reasons.join(' '), contains('repo directory missing'));
  });
}

void _git(List<String> args, {String? cwd}) {
  final r = Process.runSync('git', args, workingDirectory: cwd);
  if (r.exitCode != 0) {
    fail('git ${args.first} failed: ${r.stderr}');
  }
}
