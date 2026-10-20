import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:test/test.dart';

/// ADR-0047: the refresh spec owns the mechanics — fresh-skip, single
/// flight, cooldown across processes, staged build, atomic rename,
/// last-known-good on failure.
void main() {
  late Directory root;
  late File artifact;
  late Directory lib;
  late String lockPath;
  var builds = 0;

  ArtifactRefreshSpec spec({
    Duration cooldown = Duration.zero,
  }) =>
      ArtifactRefreshSpec(
        artifactPath: artifact.path,
        lockPath: lockPath,
        sourceRoots: [lib.path],
        cooldown: cooldown,
      );

  /// A build that stages new content (which is then newer than sources).
  Future<String?> stageBuild() async {
    builds++;
    final staged = File('${root.path}/staged-$builds.dill')
      ..writeAsStringSync('built-$builds');
    return staged.path;
  }

  /// Marks every watched source older than the artifact so the spec
  /// considers it fresh.
  void makeFresh() {
    final past = DateTime.now().subtract(const Duration(hours: 1));
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is File) entity.setLastModifiedSync(past);
    }
    if (artifact.existsSync()) artifact.setLastModifiedSync(DateTime.now());
  }

  /// Marks a watched source newer than the artifact.
  void makeStale() {
    File('${lib.path}/a.dart')
      ..writeAsStringSync('src-$builds')
      ..setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('oka-refresh-');
    artifact = File('${root.path}/out.dill')..writeAsStringSync('good-0');
    lib = Directory('${root.path}/pkg/lib')..createSync(recursive: true);
    lockPath = '${root.path}/locks/build.lock';
    builds = 0;
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('fresh skips the build', () async {
    makeFresh();
    final result = await spec().ensureFresh(build: stageBuild);
    expect(result.outcome, ArtifactRefreshOutcome.fresh);
    expect(builds, 0);
    expect(artifact.readAsStringSync(), 'good-0');
  });

  test('stale builds, renames the staged artifact atomically', () async {
    makeStale();
    final result = await spec().ensureFresh(build: stageBuild);
    expect(result.outcome, ArtifactRefreshOutcome.built);
    expect(builds, 1);
    expect(artifact.readAsStringSync(), 'built-1');
    expect(File('${root.path}/staged-1.dill').existsSync(), isFalse,
        reason: 'the staged file was consumed by the rename');
  });

  Future<String?> nullBuild() => Future<String?>.value();

  test('a null staged path fails without touching last-known-good',
      () async {
    makeStale();
    final result = await spec().ensureFresh(build: nullBuild);
    expect(result.outcome, ArtifactRefreshOutcome.failed);
    expect(artifact.readAsStringSync(), 'good-0');
  });

  Future<String?> explodingBuild() =>
      Future<String?>.error(StateError('compile exploded'));

  test('a throwing build fails with the error, last-known-good stands',
      () async {
    makeStale();
    final result = await spec().ensureFresh(build: explodingBuild);
    expect(result.outcome, ArtifactRefreshOutcome.failed);
    expect(result.error, contains('compile exploded'));
    expect(artifact.readAsStringSync(), 'good-0');
  });

  test('a lock held by another process reports inFlight and builds nothing',
      () async {
    makeStale();
    Directory(File(lockPath).parent.path).createSync(recursive: true);
    final helper = File('${root.path}/hold.dart')
      ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = File(args.single).openSync(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.drain<void>();
}
''');
    final holder = await Process.start(Platform.resolvedExecutable, [
      helper.path,
      lockPath,
    ]);
    await holder.stdout
        .transform(utf8.decoder)
        .firstWhere((line) => line.trim() == 'locked');
    try {
      final result = await spec().ensureFresh(build: stageBuild);
      expect(result.outcome, ArtifactRefreshOutcome.inFlight);
      expect(builds, 0);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  });

  test('cooldown skips a back-to-back rebuild and reports retryAfter',
      () async {
    makeStale();
    final first = await spec(cooldown: const Duration(hours: 1))
        .ensureFresh(build: stageBuild);
    expect(first.outcome, ArtifactRefreshOutcome.built);

    makeStale();
    final second = await spec(cooldown: const Duration(hours: 1))
        .ensureFresh(build: stageBuild);
    expect(second.outcome, ArtifactRefreshOutcome.cooldown);
    expect(second.retryAfter, isNotNull);
    expect(second.retryAfter!.inMinutes, greaterThan(55));
    expect(builds, 1);
  });

  test('cooldown zero never skips; cooldown elapsed rebuilds', () async {
    makeStale();
    await spec(cooldown: const Duration(hours: 1))
        .ensureFresh(build: stageBuild);
    // Backdate the stamp past the cooldown window.
    File('$lockPath.lastStart')
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    makeStale();
    final result = await spec(cooldown: const Duration(hours: 1))
        .ensureFresh(build: stageBuild);
    expect(result.outcome, ArtifactRefreshOutcome.built);
    expect(builds, 2);
  });
}
