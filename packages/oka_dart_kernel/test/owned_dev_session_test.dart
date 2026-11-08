import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_dart_kernel/src/gate/owned_dev_session_start_controller.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'owned_dev_session_test_support.dart';

const _linuxProcTokenHelper = r'''
Future<String?> linuxFixtureStartToken(int pid) async {
  if (!Platform.isLinux) return null;
  try {
    final stat = await File('/proc/$pid/stat').readAsString();
    final bootId =
        (await File('/proc/sys/kernel/random/boot_id').readAsString()).trim();
    final close = stat.lastIndexOf(')');
    final startTicks = stat.substring(close + 2).trim().split(' ')[19];
    return '$bootId:$startTicks';
  } on Object {
    return null;
  }
}
''';

const _stubSource = '''
import 'dart:convert';
import 'dart:io';

$_linuxProcTokenHelper
'''
    r'''

Future<void> main(List<String> args) async {
  final hang = args.contains('--hang-on-quit');
  if (args.contains('--spawn-on-start')) {
    final c = await Process.start('sleep', ['180']);
    final token = await linuxFixtureStartToken(c.pid);
    stderr.writeln(
      'oka_dev_fixture_escaped_pid=${c.pid} token=${token ?? 'missing'}',
    );
    await stderr.flush();
  }
  stdout.writeln('dev: ready — commands: r [file] | R | q');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t == 'q') {
      if (args.contains('--spawn-on-q')) {
        await Process.start('sleep', ['180']);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        exit(0);
      }
      if (args.contains('--spawn-on-q-setsid')) {
        final detached = await Process.start(
          'setsid',
          ['sleep', '180'],
          mode: ProcessStartMode.detached,
        );
        final token = await linuxFixtureStartToken(detached.pid);
        stderr.writeln(
          'oka_dev_fixture_escaped_pid=${detached.pid} token=${token ?? 'missing'}',
        );
        await stderr.flush();
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

void _workspaceMarkers(Directory root) {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: oka_workspace\n');
  File(p.join(root.path, 'packages', 'oka', 'pubspec.yaml')).createSync(recursive: true);
  File(p.join(root.path, 'packages', 'oka_dart_kernel', 'pubspec.yaml'))
      .createSync(recursive: true);
}

late Directory _scratch;
late String _stub;

void main() {
  setUpAll(() async {
    _scratch = await Directory.systemTemp.createTemp('oka_owned_dev_session');
    _workspaceMarkers(_scratch);
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
      useSubreaperSupervisor: false,
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final td = await session.teardown(quitGrace: const Duration(seconds: 5));
    expect(td.verified, isTrue, reason: td.notes.join('; '));
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

    const liveness = HostProcessLiveness();
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: const [],
      useSubreaperSupervisor: false,
      spawn: orphanSpawn,
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final trackedChild = session.ownershipLedger.descendantPids.toList();
    expect(trackedChild, isNotEmpty, reason: 'sleep child must be owned at ready');

    await Future<void>.delayed(const Duration(milliseconds: 200));

    final td = await session.teardown(quitGrace: const Duration(seconds: 1));
    expect(td.survivors, isEmpty, reason: td.notes.join('; '));
    expect(td.verified, isTrue);
    expect(td.clean, isTrue);
    for (final pid in trackedChild) {
      expect(await liveness.isAlive(pid), isFalse,
          reason: 'owned sleep $pid must be terminated');
    }
    expect(await liveness.isAlive(decoy.pid), isTrue,
        reason: 'unrelated decoy must survive owned teardown');
  });

  test('teardown: hang-on-quit physically terminates owned tree', () async {
    const liveness = HostProcessLiveness();
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub, '--hang-on-quit'],
      useSubreaperSupervisor: false,
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final tracked = session.ownershipLedger.allTrackedPids;

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
    expect(td.verified, isTrue);
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

    final decoy = await Process.start('sleep', ['3600']);
    addTearDown(() {
      if (decoy.pid > 0) {
        Process.killPid(decoy.pid, ProcessSignal.sigkill);
      }
    });

    await session.sendLine('q');
    final td = await session.teardown(quitGrace: const Duration(seconds: 5));
    expect(td.verified, isTrue, reason: td.notes.join('; '));
    expect(td.clean, isTrue, reason: td.notes.join('; '));
    for (final pid in td.survivors) {
      expect(await liveness.isAlive(pid), isFalse);
    }
    final ledgerPids = session.ownershipLedger.descendantPids;
    for (final pid in ledgerPids) {
      expect(await liveness.isAlive(pid), isFalse,
          reason: 'descendant from ledger $pid');
    }
    expect(await liveness.isAlive(decoy.pid), isTrue);
  });

  test(
    'teardown: setsid child adopted by subreaper is physically terminated',
    () async {
      const liveness = HostProcessLiveness();
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-q-setsid'],
      );
      expect(await session.waitForPattern('dev: ready'), isTrue);

      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 30));
      expect(td.verified, isTrue, reason: td.notes.join('; '));
      expect(td.clean, isTrue, reason: td.notes.join('; '));
      expect(td.survivors, isEmpty);
      final escaped = fixtureEscapedFromTranscript(session.transcript);
      expect(escaped, isNotEmpty);
      expect(session.drainAck?.nonce, session.sessionNonce);
      expect(session.drainAck?.settled, isTrue);
      expect(session.drainAck?.verified, isTrue);
      for (final pid in escaped.keys) {
        expect(
          await liveness.isAlive(pid),
          isFalse,
          reason: 'fixture-reported escaped pid $pid',
        );
      }
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'posix setsid',
  );

  test(
    'regression: supervisor without drain fails verified and leaves escaped pid',
    () async {
      const liveness = HostProcessLiveness();
      final kernelRoot = await resolveOkaDartKernelRoot();
      final noDrain = p.join(
        kernelRoot,
        'test',
        'fixtures',
        'linux_subreaper_supervisor_no_drain.dart',
      );

      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-q-setsid'],
        supervisorEntrypoint: noDrain,
      );
      expect(await session.waitForPattern('dev: ready'), isTrue);
      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 30));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.clean, isFalse);
      final escaped = fixtureEscapedFromTranscript(session.transcript);
      expect(escaped, isNotEmpty);
      expect(session.drainAck?.settled, isFalse);
      expect(session.drainAck?.verified, isFalse);
      for (final pid in escaped.keys) {
        addTearDown(() async {
          if (await liveness.isAlive(pid)) {
            await liveness.kill(pid, grace: const Duration(milliseconds: 200));
          }
        });
      }
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'posix setsid',
  );

  test('enumeration failure never claims verified clean', () async {
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub],
      useSubreaperSupervisor: false,
      treeProbe: const _UnreadableProbe(),
    );
    expect(await session.waitForPattern('dev: ready'), isTrue);
    final td = await session.teardown(quitGrace: const Duration(seconds: 2));
    expect(td.verified, isFalse);
    expect(td.clean, isFalse);
    expect(td.notes, anyElement(contains('enumeration')));
  });

  test(
    'abort during slow startup (subreaper) drains owned startup child',
    () async {
      const liveness = HostProcessLiveness();
      OwnedDevSession? bootstrapped;
      final ctl = OwnedDevSessionStartController(
        onBootstrapExtra: (s) => bootstrapped = s,
      );
      Process? spawned;

      Future<Process> laggedSpawn(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
        Map<String, String>? environment,
      }) async {
        final p = await Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          environment: environment,
        );
        spawned = p;
        return p;
      }

      final startFuture = OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-start'],
        startController: ctl,
        liveness: const _SlowLiveness(),
        spawn: laggedSpawn,
      );

      for (var i = 0; i < 50 && spawned == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(spawned, isNotNull);

      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await ctl.requestAbort();
      try {
        await startFuture;
      } on Object {
        // aborted during identity capture
      }

      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await liveness.isAlive(spawned!.pid), isFalse);
      final session = bootstrapped;
      expect(session, isNotNull);
      final escapedBoot = fixtureEscapedFromTranscript(session!.transcript);
      expect(escapedBoot, isNotEmpty);
      for (final pid in escapedBoot.keys) {
        expect(
          await liveness.isAlive(pid),
          isFalse,
          reason: 'startup child fixture pid $pid',
        );
      }
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux subreaper supervisor',
  );

  test('abort during slow startup stops spawned root', () async {
    const liveness = HostProcessLiveness();
    final ctl = OwnedDevSessionStartController();
    Process? spawned;

    Future<Process> laggedSpawn(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    }) async {
      final p = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      spawned = p;
      return p;
    }

    final startFuture = OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub],
      useSubreaperSupervisor: false,
      startController: ctl,
      liveness: const _SlowLiveness(),
      spawn: laggedSpawn,
    );

    for (var i = 0; i < 50 && spawned == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(spawned, isNotNull);

    final decoy = await Process.start('sleep', ['3600']);
    addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

    await ctl.requestAbort();
    try {
      await startFuture;
    } on Object {
      // aborted during identity capture
    }

    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await liveness.isAlive(spawned!.pid), isFalse);
    expect(await liveness.isAlive(decoy.pid), isTrue);
  });
}

final class _UnreadableProbe implements ProcessTreeProbe {
  const _UnreadableProbe();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

final class _SlowLiveness implements ProcessLiveness {
  const _SlowLiveness();

  @override
  Future<String?> identityToken(int pid) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    return const HostProcessLiveness().identityToken(pid);
  }

  @override
  Future<bool> isAlive(int pid) => const HostProcessLiveness().isAlive(pid);

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) =>
      const HostProcessLiveness().kill(pid, grace: grace);
}
