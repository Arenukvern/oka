// ADR-0018 L0 — emulator lease integration: spawn-side lease recording,
// identity-verified failure-path kill (problem A), and the adopt/reuse
// borrowed-flip (§3). No real emulator: scripted adb runner + fake
// dart:io Process + fake liveness seam; the skip guard is only needed
// because BootEmulatorStep resolves tool paths before the injected
// runners matter (adr0013 test pattern).
import 'dart:async';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

BuildContext _ctx(final Directory temp) => BuildContext(
      projectPath: temp.path,
      buildDir: '${temp.path}/.oka_cache/build',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '${temp.path}/.oka_cache',
    );

/// Scripted adb/avdmanager runner: records argv, replies from a script.
typedef ScriptedReply = ProcessResult Function(String exe, List<String> args);

class FakeRunner {
  final sent = <String>[];
  ScriptedReply reply = (_, _) => ProcessResult(0, 0, '', '');

  Future<ProcessResult> call(final String exe, final List<String> args) async {
    sent.add([exe, ...args].join(' '));
    return reply(exe, args);
  }
}

/// Minimal dart:io [Process] fake — records kill, never really spawns.
class FakeIoProcess implements Process {
  FakeIoProcess(this.pid);

  @override
  final int pid;

  bool killed = false;

  @override
  bool kill([final ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  IOSink get stdin =>
      throw UnimplementedError('unused in tests');

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

/// Scripted liveness seam with a mutable token (simulates pid recycling
/// mid-run) and kill recording.
class FakeLiveness implements ProcessLiveness {
  FakeLiveness({this.alive = true, this.token = 'tok-A'});

  bool alive;
  String? token;
  final killed = <int>[];

  @override
  Future<bool> isAlive(final int pid) async => alive;

  @override
  Future<String?> identityToken(final int pid) async => token;

  @override
  Future<bool> kill(final int pid, {final Duration grace = const Duration(seconds: 3)}) async {
    killed.add(pid);
    return true;
  }
}

bool _adbAndEmulatorOnPath() {
  final dirs = Platform.environment['PATH']
          ?.split(Platform.isWindows ? ';' : ':') ??
      const [];
  bool has(final String cmd) => dirs.any(
        (final d) =>
            File('$d/$cmd').existsSync() || File('$d/$cmd.exe').existsSync(),
      );
  return has('adb') && has('emulator');
}

void main() {
  late Directory temp;
  late FakeLiveness liveness;
  late ProcessLeaseRegistry registry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka_emu_lease_');
    liveness = FakeLiveness();
    registry = ProcessLeaseRegistry(
      Directory('${temp.path}/.oka_cache/processes'),
      liveness: liveness,
    );
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('spawn lease shape: owned/ephemeral, avd identity, adb stop hint',
      () {
    final step = BootEmulatorStep(avdName: 'oka-emulator');
    final l = step.spawnLease(4242, 'tok-A', serial: 'emulator-5554');
    expect(l.id, 'emulator-oka-emulator');
    expect(l.pid, 4242);
    expect(l.kind, 'android-emulator');
    expect(l.scope, LeaseScope.ephemeral);
    expect(l.ownership, LeaseOwnership.owned);
    expect(l.identity['avd'], 'oka-emulator');
    expect(l.identity['serial'], 'emulator-5554');
    expect(l.identity[processLeasePidTokenKey], 'tok-A');
    expect(l.stopHint.tool, 'adb');
    expect(l.stopHint.args, ['-s', 'emulator-5554', 'emu', 'kill']);
  });

  test('serial never registers → spawned emulator stopped, lease removed',
      () async {
    if (!_adbAndEmulatorOnPath()) return;
    final fake = FakeRunner()
      ..reply = (_, args) {
        final a = args.join(' ');
        if (a == 'devices -l') return ProcessResult(0, 0, '', '');
        return ProcessResult(0, 0, '', '');
      };
    final spawned = <FakeIoProcess>[];
    final step = BootEmulatorStep(
      avdName: 'oka-emulator',
      bootTimeout: const Duration(milliseconds: 150),
      pollInterval: const Duration(milliseconds: 10),
      killGrace: const Duration(milliseconds: 5),
      adbPath: 'adb',
      emulatorPath: 'emulator',
      liveness: liveness,
      leaseRegistry: registry,
      runProcess: fake.call,
      startProcess: (_, _) async {
        final process = FakeIoProcess(4242);
        spawned.add(process);
        return process;
      },
    );
    final r = await step.run(_ctx(temp), PipelineState());
    expect(r.ok, isFalse);
    expect(r.error, contains('did not register'));
    expect(r.error, contains('was stopped'));
    // ADR-0018 problem A: the leaked process is stopped exactly once.
    expect(spawned.single.killed, isTrue);
    expect(liveness.killed, [4242]);
    // The failure path leaves no lease behind.
    expect(await registry.list(), isEmpty);
  });

  test('boot never completes → spawned emulator stopped, lease removed',
      () async {
    if (!_adbAndEmulatorOnPath()) return;
    final fake = FakeRunner()
      ..reply = (_, args) {
        final a = args.join(' ');
        if (a == 'devices -l') {
          return ProcessResult(0, 0, 'emulator-5560\tdevice\n', '');
        }
        if (a.contains('getprop')) return ProcessResult(0, 0, '0\n', '');
        return ProcessResult(0, 0, '', '');
      };
    final spawned = <FakeIoProcess>[];
    final step = BootEmulatorStep(
      avdName: 'oka-emulator',
      bootTimeout: const Duration(milliseconds: 150),
      pollInterval: const Duration(milliseconds: 10),
      killGrace: const Duration(milliseconds: 5),
      adbPath: 'adb',
      emulatorPath: 'emulator',
      liveness: liveness,
      leaseRegistry: registry,
      runProcess: fake.call,
      startProcess: (_, _) async {
        final process = FakeIoProcess(4242);
        spawned.add(process);
        return process;
      },
    );
    final r = await step.run(_ctx(temp), PipelineState());
    expect(r.ok, isFalse);
    expect(r.error, contains('did not finish booting'));
    expect(r.error, contains('was stopped'));
    expect(spawned.single.killed, isTrue);
    expect(await registry.list(), isEmpty);
  });

  test('pid recycled mid-run → NOT signaled, lease dropped as stale',
      () async {
    if (!_adbAndEmulatorOnPath()) return;
    final fake = FakeRunner()
      ..reply = (_, args) {
        final a = args.join(' ');
        if (a == 'devices -l') return ProcessResult(0, 0, '', '');
        return ProcessResult(0, 0, '', '');
      };
    final spawned = <FakeIoProcess>[];
    late final BootEmulatorStep step;
    step = BootEmulatorStep(
      avdName: 'oka-emulator',
      bootTimeout: const Duration(milliseconds: 150),
      pollInterval: const Duration(milliseconds: 10),
      killGrace: const Duration(milliseconds: 5),
      adbPath: 'adb',
      emulatorPath: 'emulator',
      liveness: liveness,
      leaseRegistry: registry,
      runProcess: fake.call,
      startProcess: (_, _) async {
        final process = FakeIoProcess(4242);
        spawned.add(process);
        // The OS recycles the pid right after spawn: the token the lease
        // recorded (captured at spawn) no longer matches reality.
        liveness.token = 'tok-RECYCLED';
        return process;
      },
    );
    final r = await step.run(_ctx(temp), PipelineState());
    expect(r.ok, isFalse);
    // Identity-over-pid law (ADR-0018 §1): never signal a recycled pid.
    expect(spawned.single.killed, isFalse);
    expect(liveness.killed, isEmpty);
    // The provably-stale record is dropped.
    expect(await registry.list(), isEmpty);
  });

  test('adopt path: existing owned lease flips to borrowed, kills nothing',
      () async {
    if (!_adbAndEmulatorOnPath()) return;
    final reg2 = registry;
    await reg2.upsert(
      ProcessLease(
        id: 'emulator-oka-emulator',
        pid: 4242,
        kind: 'android-emulator',
        identity: const {'avd': 'oka-emulator'},
        scope: LeaseScope.ephemeral,
        ownership: LeaseOwnership.owned,
        ownerCmd: 'oka run emulator',
        startedAt: DateTime.now().toUtc(),
        stopHint: const LeaseStopHint(tool: 'adb', args: ['emu', 'kill']),
      ),
    );
    final fake = FakeRunner()
      ..reply = (_, args) {
        final a = args.join(' ');
        if (a == 'devices -l') {
          return ProcessResult(0, 0, 'emulator-5554\tdevice\n', '');
        }
        if (a.contains('emu avd name')) {
          return ProcessResult(0, 0, 'oka-emulator\nOK', '');
        }
        return ProcessResult(0, 0, '', '');
      };
    final step = BootEmulatorStep(
      avdName: 'oka-emulator',
      adbPath: 'adb',
      emulatorPath: 'emulator',
      liveness: liveness,
      leaseRegistry: reg2,
      runProcess: fake.call,
      startProcess: (_, _) => throw StateError('reuse must not spawn'),
    );
    final state = PipelineState();
    final r = await step.run(_ctx(temp), state);
    expect(r.ok, isTrue, reason: r.error);
    expect(state[emulatorSerial.id], 'emulator-5554');
    // §3: adoption flips ownership, never signals.
    final l = await reg2.read('emulator-oka-emulator');
    expect(l?.ownership, LeaseOwnership.borrowed);
    expect(l?.identity['serial'], 'emulator-5554');
    expect(liveness.killed, isEmpty);
  });

  test('adopt path with no prior lease records one as borrowed (pid 0)',
      () async {
    if (!_adbAndEmulatorOnPath()) return;
    final reg3 = registry;
    final fake = FakeRunner()
      ..reply = (_, args) {
        final a = args.join(' ');
        if (a == 'devices -l') {
          return ProcessResult(0, 0, 'emulator-5554\tdevice\n', '');
        }
        if (a.contains('emu avd name')) {
          return ProcessResult(0, 0, 'oka-emulator\nOK', '');
        }
        return ProcessResult(0, 0, '', '');
      };
    final step = BootEmulatorStep(
      avdName: 'oka-emulator',
      adbPath: 'adb',
      emulatorPath: 'emulator',
      liveness: liveness,
      leaseRegistry: reg3,
      runProcess: fake.call,
      startProcess: (_, _) => throw StateError('reuse must not spawn'),
    );
    final r = await step.run(_ctx(temp), PipelineState());
    expect(r.ok, isTrue, reason: r.error);
    final l = await reg3.read('emulator-oka-emulator');
    expect(l?.ownership, LeaseOwnership.borrowed);
    expect(l?.pid, 0);
    expect(liveness.killed, isEmpty);
  });
}
