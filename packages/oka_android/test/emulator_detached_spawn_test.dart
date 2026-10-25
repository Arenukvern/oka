/// The emulator is spawned **detached** so a long-lived emulator does not
/// pin the CLI's lifetime (ADR-0018 §3a).
///
/// The regression these tests guard is concrete: with
/// `ProcessStartMode.normal` the Dart VM keeps the parent alive for as long
/// as the child runs ("The parent process will not exit so long as the child
/// is running"), so `oka run emulator` could never return while the
/// emulator was up — the opposite of the `stopOnExit=false` contract.
///
/// Everything here uses throwaway children (`sleep`) that this test owns and
/// stops. The live emulator is never touched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late List<int> ownedChildren;

  // The child fixture is `sleep(1)` — POSIX only.
  final skipOnWindows = Platform.isWindows ? 'POSIX-only fixture (sleep)' : null;

  setUp(() async {
    final scratch = await Directory.systemTemp.createTemp(
      'oka-detached-spawn-',
    );
    temp = Directory(await scratch.resolveSymbolicLinks());
    ownedChildren = <int>[];
  });

  tearDown(() async {
    // Stop ONLY the children this test spawned.
    const liveness = HostProcessLiveness();
    for (final pid in ownedChildren) {
      await liveness.kill(pid, grace: const Duration(milliseconds: 200));
    }
    if (temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  });

  test(
    'a detached child lets its calling process terminate while it lives',
    () async {
      final script = File('${temp.path}/detached_child.dart');
      await script.writeAsString('''
import 'dart:io';

import 'package:oka_android/src/dev/detached_spawn.dart';

Future<void> main() async {
  final process = await spawnDetachedProcess('sleep', ['30']);
  stdout.writeln('pid=' + process.pid.toString());
  await stdout.flush();
}
''');

      // The script returns immediately after spawning. If the child pinned
      // the calling process, the script would never exit and the guard
      // below would fire.
      final result = await _runScript(script);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final pid = int.parse((result.stdout as String).trim().split('=').last);
      ownedChildren.add(pid);

      // The child outlived the process that spawned it.
      const liveness = HostProcessLiveness();
      expect(
        await liveness.isAlive(pid),
        isTrue,
        reason: 'a detached child must keep running after its parent exits',
      );
    },
    skip: skipOnWindows,
  );

  test('the detached child is stopped through the identity-verified lease',
      () async {
    const liveness = HostProcessLiveness();
    final child = await Process.start(
      'sleep',
      ['30'],
      mode: ProcessStartMode.detached,
    );
    ownedChildren.add(child.pid);
    final token = await liveness.identityToken(child.pid);
    expect(token, isNotNull);

    final registry = ProcessLeaseRegistry(
      Directory('${temp.path}/leases'),
      liveness: liveness,
    );
    final lease = ProcessLease(
      id: 'detached-test-child',
      pid: child.pid,
      kind: 'test-child',
      identity: {processLeasePidTokenKey: token!},
      scope: LeaseScope.ephemeral,
      ownership: LeaseOwnership.owned,
      ownerCmd: 'oka test',
      startedAt: DateTime.now().toUtc(),
      stopHint: LeaseStopHint(tool: 'kill', args: ['-TERM', '${child.pid}']),
    );
    await registry.upsert(lease);

    final outcome = await ProcessStopPolicy(
      registry: registry,
      liveness: liveness,
      verifyGrace: const Duration(milliseconds: 200),
      pollInterval: const Duration(milliseconds: 50),
    ).stop(
      lease,
      force: false,
      gracefulStop: (lease) =>
          stopLeasedPidGracefully(liveness, lease, grace: const Duration(
            milliseconds: 200,
          )),
    );

    expect(outcome.ok, isTrue, reason: outcome.message);
    expect(await liveness.isAlive(child.pid), isFalse);
    expect(await registry.read(lease.id), isNull);
  }, skip: skipOnWindows);

  test('an unverifiable pid is refused, never signalled', () async {
    const liveness = HostProcessLiveness();
    final child = await Process.start(
      'sleep',
      ['30'],
      mode: ProcessStartMode.detached,
    );
    ownedChildren.add(child.pid);

    // A lease whose recorded token does not match the live process: the
    // pid may belong to someone else now.
    final stale = ProcessLease(
      id: 'detached-test-stale',
      pid: child.pid,
      kind: 'test-child',
      identity: const {processLeasePidTokenKey: 'not-the-recorded-token'},
      scope: LeaseScope.ephemeral,
      ownership: LeaseOwnership.owned,
      ownerCmd: 'oka test',
      startedAt: DateTime.now().toUtc(),
      stopHint: LeaseStopHint(tool: 'kill', args: ['-TERM', '${child.pid}']),
    );

    final refused = await stopLeasedPidGracefully(
      liveness,
      stale,
      grace: const Duration(milliseconds: 200),
    );
    expect(refused, isFalse);
    expect(
      await liveness.isAlive(child.pid),
      isTrue,
      reason: 'a pid whose identity cannot be verified must never be signalled',
    );
  }, skip: skipOnWindows);

  test('BootEmulatorStep spawns detached and stops exactly its own child',
      () async {
    final project = Directory('${temp.path}/project')..createSync();
    final modes = <ProcessStartMode>[];
    int? childPid;

    final step = BootEmulatorStep(
      avdName: 'oka-detached-test',
      bootTimeout: const Duration(milliseconds: 400),
      pollInterval: const Duration(milliseconds: 20),
      killGrace: const Duration(milliseconds: 200),
      adbPath: '/fake/adb',
      emulatorPath: '/fake/emulator',
      // No emulator ever registers a serial, so the step takes its
      // failure path: stop exactly the process we spawned.
      runProcess: (_, _) async => ProcessResult(0, 0, '', ''),
      startProcessWithMode: (executable, args, mode) async {
        modes.add(mode);
        final child = await Process.start('sleep', ['30'], mode: mode);
        childPid = child.pid;
        ownedChildren.add(child.pid);
        return child;
      },
    );

    final result = await step.run(
      BuildContext(
        projectPath: project.path,
        buildDir: '${project.path}/build',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      ),
      PipelineState(),
    );

    expect(modes, [ProcessStartMode.detached]);
    expect(result.ok, isFalse);
    expect(result.error, contains('was stopped'));
    expect(
      await const HostProcessLiveness().isAlive(childPid!),
      isFalse,
      reason: 'the failure path must stop exactly the process it spawned',
    );
    final registry = ProcessLeaseRegistry.forProject(project.path);
    expect(
      await registry.read('emulator-oka-detached-test'),
      isNull,
      reason: 'a verified stop removes the lease record',
    );
  }, skip: skipOnWindows);

  test('BootEmulatorStep refuses to signal an unverifiable pid', () async {
    final project = Directory('${temp.path}/project')..createSync();
    final liveness = _ScriptedLiveness();
    int? childPid;

    final step = BootEmulatorStep(
      avdName: 'oka-detached-test',
      bootTimeout: const Duration(milliseconds: 400),
      pollInterval: const Duration(milliseconds: 20),
      killGrace: const Duration(milliseconds: 200),
      adbPath: '/fake/adb',
      emulatorPath: '/fake/emulator',
      liveness: liveness,
      runProcess: (_, _) async => ProcessResult(0, 0, '', ''),
      startProcessWithMode: (executable, args, mode) async {
        final child = await Process.start('sleep', ['30'], mode: mode);
        childPid = child.pid;
        ownedChildren.add(child.pid);
        return child;
      },
    );

    final result = await step.run(
      BuildContext(
        projectPath: project.path,
        buildDir: '${project.path}/build',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      ),
      PipelineState(),
    );

    expect(result.ok, isFalse);
    expect(
      liveness.killCalls,
      0,
      reason: 'an unverifiable identity must never reach a signal',
    );
    expect(
      await const HostProcessLiveness().isAlive(childPid!),
      isTrue,
      reason: 'the child must survive an unverifiable teardown',
    );
    final registry = ProcessLeaseRegistry.forProject(project.path);
    expect(
      await registry.read('emulator-oka-detached-test'),
      isNotNull,
      reason: 'an unverifiable teardown retains the lease for reconciliation',
    );
  }, skip: skipOnWindows);
}

/// Runs [script] with the workspace package config, and fails the test if
/// the calling process does not terminate on its own.
Future<ProcessResult> _runScript(File script) async {
  final config = _packageConfig().absolute.path;
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['--packages=$config', script.absolute.path],
  );
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    fail(
      'the spawned child pinned the calling process: it did not terminate '
      'within 60s (this is the CLI-lifetime regression)',
    );
  }
  return ProcessResult(process.pid, exitCode, await out, await err);
}

/// The nearest package config at or above the current directory (pub
/// workspaces keep it at the repository root).
File _packageConfig() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = File('${dir.path}/.dart_tool/package_config.json');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'no package_config.json found at or above ${Directory.current.path}',
      );
    }
    dir = parent;
  }
}

/// A liveness seam whose identity token is obtainable exactly once (at spawn
/// time) and unverifiable afterwards.
class _ScriptedLiveness implements ProcessLiveness {
  int _tokenCalls = 0;
  int killCalls = 0;

  @override
  Future<bool> isAlive(int pid) async => true;

  @override
  Future<String?> identityToken(int pid) async {
    _tokenCalls++;
    return _tokenCalls == 1 ? 'scripted-token' : null;
  }

  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 3),
  }) async {
    killCalls++;
    return false;
  }
}
