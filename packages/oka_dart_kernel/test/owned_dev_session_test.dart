import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _stubSource = '''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final hang = args.contains('--hang-on-quit');
  stdout.writeln('dev: ready — commands: r [file] | R | q');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t == 'q') {
      if (args.contains('--spawn-on-q')) {
        await Process.start('sleep', ['180']);
        await Future<void>.delayed(const Duration(seconds: 2));
        exit(0);
      }
      if (hang) {
        await Future<void>.delayed(const Duration(hours: 1));
      }
      exit(0);
    }
    if (t == 'R') {
      stdout.writeln('Restarted application in 1ms.');
      stdout.writeln('restart: OK (platform lane, 1ms)');
    }
    if (t.startsWith('r')) {
      stdout.writeln('reload 1: OK');
    }
  }
}
''';

late Directory _scratch;
late String _stub;

void main() {
  setUpAll(() async {
    _scratch = await Directory.systemTemp.createTemp('oka_owned_dev_session');
    _stub = p.join(_scratch.path, 'stub.dart');
    await File(_stub).writeAsString(_stubSource);
  });

  tearDownAll(() async {
    await _scratch.delete(recursive: true);
  });

  test('teardown: q exits cleanly with no survivors', () async {
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub],
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final td = await session.teardown(quitGrace: const Duration(seconds: 5));
    expect(td.clean, isTrue, reason: td.notes.join('; '));
    expect(td.survivors, isEmpty);
  });

  test('teardown: root exited early still stops owned child, not decoy', () async {
    const launcher = '''
#!/bin/sh
sleep 180 &
echo "dev: ready — commands: r [file] | R | q"
sleep 1
exit 0
''';
    final script = File('${_scratch.path}/orphan_launcher.sh')
      ..writeAsStringSync(launcher);
    await Process.run('chmod', ['+x', script.path]);

    final decoy = await Process.start('sleep', ['3600']);
    addTearDown(() {
      if (decoy.pid > 0) {
        Process.killPid(decoy.pid, ProcessSignal.sigkill);
      }
    });

    Future<Process> orphanSpawn(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    }) =>
        Process.start(
          '/bin/sh',
          [script.path],
          workingDirectory: workingDirectory,
          environment: environment,
        );

    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: const [],
      spawn: orphanSpawn,
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    await session.snapshotOwnedTree();
    expect(
      session.ownedTree,
      isNotNull,
      reason: 'tree + identities must be captured while root was alive',
    );
    expect(
      session.ownedTree!.descendantPids,
      isNotEmpty,
      reason: 'launcher must own a sleep child',
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));

    final td = await session.teardown(quitGrace: const Duration(seconds: 1));
    expect(td.survivors, isEmpty, reason: td.notes.join('; '));
    expect(td.clean, isTrue);

    expect(await const HostProcessLiveness().isAlive(decoy.pid), isTrue,
        reason: 'unrelated decoy must survive owned teardown');
  });

  test('teardown: hang-on-quit physically terminates owned tree', () async {
    const liveness = HostProcessLiveness();
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub, '--hang-on-quit'],
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    await session.snapshotOwnedTree();
    final tracked = session.ownedTree!.allTrackedPids;

  final decoy = await Process.start('sleep', ['3600']);
  addTearDown(() {
    if (decoy.pid > 0) {
      Process.killPid(decoy.pid, ProcessSignal.sigkill);
    }
  });

    final td = await session.teardown(
      quitGrace: const Duration(milliseconds: 200),
      stopGrace: const Duration(seconds: 3),
    );
    expect(td.survivors, isEmpty, reason: td.notes.join('; '));
    expect(td.clean, isTrue);
    for (final pid in tracked) {
      expect(
        await liveness.isAlive(pid),
        isFalse,
        reason: 'tracked pid $pid must be terminated',
      );
    }
    expect(await liveness.isAlive(decoy.pid), isTrue);
  });

  test('teardown: q spawns owned sleep then exits; sleep must not survive', () async {
    const liveness = HostProcessLiveness();
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub, '--spawn-on-q'],
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
    );
    await session.snapshotOwnedTree();
    expect(session.ownedTree!.descendantPids, isEmpty);

    final decoy = await Process.start('sleep', ['3600']);
    addTearDown(() {
      if (decoy.pid > 0) {
        Process.killPid(decoy.pid, ProcessSignal.sigkill);
      }
    });

    session.sendLine('q');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await session.snapshotOwnedTree();
    final ownedSleep = session.ownedTree?.descendantPids ?? const <int>[];
    expect(ownedSleep, isNotEmpty, reason: 'q must leave an owned sleep child');

    final td = await session.teardown(quitGrace: const Duration(seconds: 1));
    expect(td.clean, isTrue, reason: td.notes.join('; '));
    for (final pid in ownedSleep) {
      expect(await liveness.isAlive(pid), isFalse);
    }
    expect(await liveness.isAlive(decoy.pid), isTrue);
  });
}
