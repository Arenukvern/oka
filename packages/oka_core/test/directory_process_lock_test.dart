import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

final class _AlwaysAlive implements ProcessLiveness {
  @override
  Future<bool> isAlive(final int pid) async => pid > 0;

  @override
  Future<String?> identityToken(final int pid) async => 'tok-$pid';

  @override
  Future<bool> kill(final int pid, {final Duration grace = Duration.zero}) async =>
      false;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka-dir-lock-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('acquires empty lock and writes pid', () async {
    final lock = DirectoryProcessLock(
      Directory('${temp.path}/lane.lock'),
      label: 'test',
    );
    expect(await lock.tryAcquire(), isTrue);
    expect(lock.holderPid(), pid);
    lock.release();
    expect(Directory('${temp.path}/lane.lock').existsSync(), isFalse);
  });

  test('refuses when another live holder owns the lock', () async {
    final dir = Directory('${temp.path}/lane.lock')..createSync();
    // Simulate a foreign live holder (pid 0 is never "us"; use fake liveness).
    File('${dir.path}/pid').writeAsStringSync('pid=424242\n');
    final lock = DirectoryProcessLock(
      dir,
      label: 'b',
      liveness: _AlwaysAlive(),
    );
    expect(await lock.tryAcquire(), isFalse);
  });

  test('steals stale lock from dead pid', () async {
    final dir = Directory('${temp.path}/lane.lock')..createSync();
    File('${dir.path}/pid').writeAsStringSync('pid=1\n'); // PID 1 may be init;
    // Use a definitely-dead high pid that isAlive should reject on unix.
    File('${dir.path}/pid').writeAsStringSync('pid=2147483000\n');
    final lock = DirectoryProcessLock(dir, label: 'steal');
    expect(await lock.tryAcquire(), isTrue);
    expect(lock.holderPid(), pid);
    lock.release();
  });
}
