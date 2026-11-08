import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';
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
  if (args.contains('--forge-workload-pid')) {
    final bait = await Process.start('sleep', ['3600']);
    final line = 'oka_dev_workload_pid=${bait.pid}';
    stdout.writeln(line);
    stderr.writeln(line);
  }
  if (args.contains('--forge-ack')) {
    const fake =
        'oka_dev_supervisor_drain_ack nonce=stolen settled=true verified=true survivors=';
    stdout.writeln(fake);
    stderr.writeln(fake);
  }
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
      exit(0);
    }
  }
}
''';

late Directory _scratch;
late String _stub;

void _workspaceMarkers(Directory root) {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: oka_workspace\n');
  File(p.join(root.path, 'packages', 'oka', 'pubspec.yaml')).createSync(recursive: true);
  File(p.join(root.path, 'packages', 'oka', 'pubspec.yaml'))
      .writeAsStringSync('name: oka\n');
  File(p.join(root.path, 'packages', 'oka_dart_kernel', 'pubspec.yaml'))
      .createSync(recursive: true);
  File(p.join(root.path, 'packages', 'oka_dart_kernel', 'pubspec.yaml'))
      .writeAsStringSync('name: oka_dart_kernel\n');
}

Future<String> _fixture(String name) async {
  final kernelRoot = await resolveOkaDartKernelRoot();
  return p.join(kernelRoot, 'test', 'fixtures', name);
}

void main() {
  setUpAll(() async {
    _scratch = await Directory.systemTemp.createTemp('oka_owned_adversarial');
    _workspaceMarkers(_scratch);
    _stub = p.join(_scratch.path, 'stub.dart');
    await File(_stub).writeAsString(_stubSource);
  });

  tearDownAll(() async {
    await _scratch.delete(recursive: true);
  });

  test(
    'mutation: no-drain + setsid must not pass physical success',
    () async {
      const liveness = HostProcessLiveness();
      final noDrain = await _fixture('linux_subreaper_supervisor_no_drain.dart');
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-q-setsid'],
        supervisorEntrypoint: noDrain,
      );
      await session.waitForPattern('dev: ready');
      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 12));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.clean, isFalse);
      final escaped = fixtureEscapedFromTranscript(session.transcript);
      expect(escaped, isNotEmpty);
      for (final pid in escaped.keys) {
        expect(
          await liveness.isAlive(pid),
          isTrue,
          reason: 'escaped fixture pid $pid must survive disabled drain',
        );
        addTearDown(() async {
          if (await liveness.isAlive(pid)) await liveness.kill(pid);
        });
      }
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'control ack plus abnormal supervisor exit 42 is unverified',
    () async {
      final exit42 = await _fixture('linux_subreaper_supervisor_exit42.dart');
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub],
        supervisorEntrypoint: exit42,
      );
      await session.waitForPattern('dev: ready');
      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 8));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.exitCode, 42);
      expect(td.notes, anyElement(contains('nonzero')));
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'spoofed success control ack without drain plus setsid stays unverified',
    () async {
      const liveness = HostProcessLiveness();
      final spoof = await _fixture(
        'linux_subreaper_supervisor_spoof_success_no_drain.dart',
      );
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-q-setsid'],
        supervisorEntrypoint: spoof,
      );
      await session.waitForPattern('dev: ready');
      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 30));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.clean, isFalse);
      expect(session.drainAck?.verified, isTrue);
      final escaped = fixtureEscapedFromTranscript(session.transcript);
      expect(escaped, isNotEmpty);
      for (final pid in escaped.keys) {
        expect(await liveness.isAlive(pid), isTrue);
        addTearDown(() async {
          if (await liveness.isAlive(pid)) {
            await liveness.kill(pid, grace: const Duration(milliseconds: 200));
          }
        });
      }
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'workload forged ack on stdout and stderr does not verify without control',
    () async {
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--forge-ack'],
        supervisorEntrypoint:
            await _fixture('linux_subreaper_supervisor_exit42.dart'),
      );
      await session.waitForPattern('dev: ready');
      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 8));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(session.transcript, contains('nonce=stolen'));
      expect(td.notes, anyElement(contains('nonzero')));
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'control ack plus supervisor SIGABRT exit (134) is unverified',
    () async {
      final sigabrt = await _fixture('linux_subreaper_supervisor_sigabrt.dart');
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--forge-ack'],
        supervisorEntrypoint: sigabrt,
      );
      await session.waitForPattern('dev: ready');
      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 10));
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.exitCode, isNot(0));
      expect(td.notes, anyElement(contains('nonzero')));
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'lost drain ack (supervisor exits without ack) => unverified',
    () async {
      const liveness = HostProcessLiveness();
      final noAck = await _fixture('linux_subreaper_supervisor_no_ack.dart');
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub],
        supervisorEntrypoint: noAck,
      );
      await session.waitForPattern('dev: ready');
      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await session.sendLine('q');
      final td = await session.teardown(quitGrace: const Duration(seconds: 8));
      expect(td.verified, isFalse);
      expect(session.drainAck, isNull);
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'SIGKILL supervisor before control ack => unverified, sentinel safe',
    () async {
      const liveness = HostProcessLiveness();
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-q-setsid'],
      );
      await session.waitForPattern('dev: ready');
      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      await session.sendLine('q');
      final tdFuture = session.teardown(quitGrace: const Duration(seconds: 15));
      for (var i = 0; i < 80; i++) {
        if (session.drainAck == null &&
            await liveness.isAlive(session.process.pid)) {
          Process.killPid(session.process.pid, ProcessSignal.sigkill);
        }
        if (session.drainAck != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      final td = await tdFuture;
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'supervisorEntrypoint outside fixtures is rejected',
    () async {
      final evil = File('${_scratch.path}/evil_supervisor.dart')
        ..writeAsStringSync('void main() {}');
      await expectLater(
        OwnedDevSession.start(
          workspace: _scratch.path,
          dartInvocation: [_stub],
          supervisorEntrypoint: evil.path,
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'startup abort with unavailable listing stays unverified',
    () async {
      OwnedDevSession? bootstrapped;
      final ctl = OwnedDevSessionStartController(
        onBootstrapExtra: (s) => bootstrapped = s,
      );
      final startFuture = OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--spawn-on-start'],
        startController: ctl,
        treeProbe: const _UnavailableProcessTreeProbe(),
        liveness: const _StartupSlowLiveness(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await ctl.requestAbort();
      try {
        await startFuture;
      } on Object {
        // expected abort
      }
      final td = await bootstrapped?.teardown();
      expect(td?.verified, isFalse);
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'forged workload pid on stdout and stderr does not redirect ownership',
    () async {
      const liveness = HostProcessLiveness();
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub, '--forge-workload-pid'],
      );
      await session.waitForPattern('dev: ready');
      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));
      await session.sendLine('q');
      await session.teardown(quitGrace: const Duration(seconds: 30));
      expect(await liveness.isAlive(decoy.pid), isTrue);
      final bait = RegExp(r'^oka_dev_workload_pid=(\d+)$', multiLine: true)
          .firstMatch(session.transcript);
      expect(bait, isNotNull);
      expect(session.authorityWorkloadPid, isNotNull);
      if (bait != null) {
        final baitPid = int.parse(bait.group(1)!);
        expect(session.authorityWorkloadPid, isNot(baitPid));
        expect(baitPid, isNot(decoy.pid));
      }
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'valid control ack with hanging supervisor wrapper is unverified',
    () async {
      final hang =
          await _fixture('linux_subreaper_supervisor_hang_after_ack.dart');
      final session = await OwnedDevSession.start(
        workspace: _scratch.path,
        dartInvocation: [_stub],
        supervisorEntrypoint: hang,
      );
      await session.waitForPattern('dev: ready');
      await session.sendLine('q');
      final td = await session.teardown(
        quitGrace: const Duration(seconds: 3),
        stopGrace: const Duration(seconds: 3),
      );
      expect(td.verified, isFalse, reason: td.notes.join('; '));
      expect(td.clean, isFalse);
      expect(td.exitCode, isNot(0));
    },
    skip: Platform.isLinux ? false : 'linux supervisor',
  );

  test(
    'incomplete liveness inspection within budget is unverified',
    () async {
      final child = await Process.start('sleep', ['60']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final result = await drainSubreaperAdoptees(
        supervisorPid: 1,
        probe: _SlowListingProbe(
          delay: Duration.zero,
          descendants: [child.pid],
        ),
        liveness: const _SlowAliveLiveness(),
        budget: const Duration(milliseconds: 15),
      );
      expect(result.settled, isFalse);
      expect(result.verified, isFalse);
      expect(
        result.notes,
        anyElement(contains('incomplete descendant liveness inspection')),
      );
      expect(await const HostProcessLiveness().isAlive(child.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux drain',
  );
}

final class _UnavailableProcessTreeProbe implements ProcessTreeProbe {
  const _UnavailableProcessTreeProbe();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

final class _StartupSlowLiveness implements ProcessLiveness {
  const _StartupSlowLiveness();

  @override
  Future<String?> identityToken(int pid) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return const HostProcessLiveness().identityToken(pid);
  }

  @override
  Future<bool> isAlive(int pid) => const HostProcessLiveness().isAlive(pid);

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) =>
      const HostProcessLiveness().kill(pid, grace: grace);
}

final class _SlowListingProbe implements ProcessTreeProbe {
  _SlowListingProbe({required this.delay, this.descendants = const []});

  final Duration delay;
  final List<int> descendants;

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    await Future<void>.delayed(delay);
    return ProcessTree(
      rootPid: rootPid,
      parentOf: {
        rootPid: 0,
        for (final d in descendants) d: rootPid,
      },
    );
  }
}

final class _SlowAliveLiveness implements ProcessLiveness {
  const _SlowAliveLiveness();

  @override
  Future<bool> isAlive(int pid) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return true;
  }

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) async => false;

  @override
  Future<String?> identityToken(int pid) async => 'probe-token-$pid';
}
