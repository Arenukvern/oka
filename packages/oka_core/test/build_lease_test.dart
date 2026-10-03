import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory projectDir;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('oka_lease_home_');
    projectDir = await Directory.systemTemp.createTemp('oka_lease_proj_');
    BuildLease.homeOverride = home.path;
  });

  tearDown(() async {
    BuildLease.homeOverride = null;
    await home.delete(recursive: true);
    await projectDir.delete(recursive: true);
  });

  test('acquire writes both lock files, release removes them', () async {
    final lease = await BuildLease.acquire('test build', projectDir: projectDir.path);
    expect(
      File('${home.path}/.oka/build.lock').existsSync(),
      isTrue,
    );
    expect(
      File('${projectDir.path}/.dart_tool/oka_build.lock').existsSync(),
      isTrue,
    );
    await lease.release();
    expect(
      File('${home.path}/.oka/build.lock').existsSync(),
      isFalse,
    );
    expect(
      File('${projectDir.path}/.dart_tool/oka_build.lock').existsSync(),
      isFalse,
    );
  });

  test('a live holder refuses a second acquire(wait: false)', () async {
    final lease = await BuildLease.acquire('first', projectDir: projectDir.path);
    await expectLater(
      BuildLease.acquire('second', projectDir: projectDir.path, wait: false),
      throwsA(isA<BuildLeaseHeldException>()),
    );
    await lease.release();
  });

  test('a dead holder is stale: takeover with a loud warning', () async {
    // A real process, then killed — its pid is reliably dead.
    final dead = await Process.start('sleep', ['30']);
    dead.kill();
    await dead.exitCode;
    final globalLock = File('${home.path}/.oka/build.lock');
    globalLock.createSync(recursive: true);
    globalLock.writeAsStringSync(
      '{"pid": ${dead.pid}, "command": "dead build", '
      '"startedAt": "2026-10-02T00:00:00Z"}',
    );
    final lease = await BuildLease.acquire('fresh build');
    // The takeover replaced the stale file with OUR token.
    final holder = globalLock.readAsStringSync();
    expect(holder, contains('fresh build'));
    await lease.release();
  });

  test('withLease runs the body and releases on throw', () async {
    var ran = false;
    await expectLater(
      BuildLease.withLease<void>('throwing build', () {
        ran = true;
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(ran, isTrue);
    expect(File('${home.path}/.oka/build.lock').existsSync(), isFalse);
  });
}
