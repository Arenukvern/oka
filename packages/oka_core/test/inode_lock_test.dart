import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

/// ADR-0047: InodeLock is the build single-flight dialect — contention is
/// cross-process only, and the kernel releases the lock on process death,
/// so a killed builder can never suppress a refresh.
void main() {
  late Directory root;
  late File lockFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('oka-inode-lock-');
    lockFile = File('${root.path}/build.lock');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  /// Spawns a child that takes the lock and holds it until stdin closes.
  Future<Process> holder() async {
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
    final process = await Process.start(
      Platform.resolvedExecutable,
      [helper.path, lockFile.path],
    );
    await process.stdout
        .transform(utf8.decoder)
        .firstWhere((line) => line.trim() == 'locked');
    return process;
  }

  test('a second process cannot acquire while a holder lives', () async {
    final held = await holder();
    try {
      expect(await InodeLock.tryAcquire(lockFile), isNull);
    } finally {
      held.kill();
      await held.exitCode;
    }
  });

  test('release allows re-acquire', () async {
    final first = await InodeLock.tryAcquire(lockFile);
    expect(first, isNotNull);
    await first!.close();
    final second = await InodeLock.tryAcquire(lockFile);
    expect(second, isNotNull);
    await second!.close();
  });

  test('a SIGKILLed holder releases the lock without deleting its inode',
      () async {
    final held = await holder();
    final inodeBefore = lockFile.statSync().mode; // file exists
    expect(inodeBefore, greaterThan(0));
    held.kill(ProcessSignal.sigkill);
    await held.exitCode;
    final lock = await InodeLock.tryAcquire(lockFile);
    expect(lock, isNotNull, reason: 'kernel must drop fcntl locks on death');
    await lock!.close();
  });
}
