// ADR-0013 T2 / ADR-0015: the emulator lifecycle as a composable target —
// pure argv builders, scripted-fake process execution (no real emulator in
// unit tests), idempotent reuse, and fail-closed provisioning remediation.
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

BuildContext _ctx() => const BuildContext(
      projectPath: '/tmp/x',
      buildDir: '/tmp/x/.oka_cache',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '/tmp/x/.oka_cache',
    );

/// Scripted adb/avdmanager/emulator runner: records argv, replies from a
/// script keyed by a matcher on the args.
typedef ScriptedReply = ProcessResult Function(String exe, List<String> args);

class FakeRunner {
  final sent = <String>[];
  ScriptedReply reply = (_, _) => ProcessResult(0, 0, '', '');

  Future<ProcessResult> call(final String exe, final List<String> args) async {
    sent.add([exe, ...args].join(' '));
    return reply(exe, args);
  }
}

void main() {
  group('pure argv builders', () {
    test('emulator launch args: headless by default', () {
      expect(
        emulatorLaunchArgs(name: 'oka-emulator'),
        ['-avd', 'oka-emulator', '-no-window', '-no-audio', '-no-boot-anim',
         '-no-snapshot-save'],
      );
    });

    test('avdmanager create args carry name + package + optional device', () {
      expect(
        avdManagerCreateArgs(name: 'a', image: 'sys', deviceProfile: 'pixel'),
        ['create', 'avd', '--force', '--name', 'a', '--package', 'sys',
         '--device', 'pixel'],
      );
      expect(
        avdManagerCreateArgs(name: 'a', image: 'sys'),
        ['create', 'avd', '--force', '--name', 'a', '--package', 'sys'],
      );
    });

    test('parseAvdManagerNames reads Name: blocks', () {
      expect(
        parseAvdManagerNames(
          'INFO | loading\n\tName: oka-emulator\n\tPath: /x\n\tName: h0test\n',
        ),
        ['oka-emulator', 'h0test'],
      );
    });

    test('parseEmuAvdName takes the first line, drops OK', () {
      expect(parseEmuAvdName('oka-a\nOK'), 'oka-a');
      expect(parseEmuAvdName('OK'), isNull);
    });

    test('parseBootCompleted is strict', () {
      expect(parseBootCompleted('1\n'), isTrue);
      expect(parseBootCompleted(''), isFalse);
      expect(parseBootCompleted('0'), isFalse);
    });

    test('host ABI default maps to a system-image ABI', () {
      expect(defaultAbi(), anyOf('arm64-v8a', 'x86_64'));
    });
  });

  group('EnsureAvdStep', () {
    test('existing AVD is a no-op success', () async {
      final fake = FakeRunner()
        ..reply = (_, _) =>
            ProcessResult(0, 0, 'Name: oka-emulator\nPath: /x\n', '');
      final step = EnsureAvdStep(
        avdName: 'oka-emulator',
        systemImage: 'system-images;android-34;google_apis;arm64-v8a',
        runProcess: fake.call,
      );
      final r = await step.run(_ctx(), PipelineState());
      expect(r.ok, isTrue);
      expect(fake.sent, hasLength(1), reason: 'list only, no create');
      expect(fake.sent.single, contains('list avd'));
    });

    test('missing AVD + createIfMissing runs avdmanager create', () async {
      final fake = FakeRunner()
        ..reply = (_, _) => ProcessResult(0, 0, '', '');
      final step = EnsureAvdStep(
        avdName: 'oka-emulator',
        systemImage: 'system-images;android-34;google_apis;arm64-v8a',
        runProcess: fake.call,
      );
      final r = await step.run(_ctx(), PipelineState());
      expect(r.ok, isTrue);
      expect(fake.sent.where((s) => s.contains('create avd')), hasLength(1));
      expect(fake.sent.join(' '), contains('system-images;android-34'));
    });

    test('missing system image fails closed naming the sdkmanager command',
        () async {
      final fake = FakeRunner()
        ..reply = (_, _) => ProcessResult(
              1,
              0,
              '',
              "Error: Could not find or has not been downloaded 'sys'",
            );
      final step = EnsureAvdStep(
        avdName: 'oka-emulator',
        systemImage: 'system-images;android-34;google_apis;arm64-v8a',
        runProcess: fake.call,
      );
      final r = await step.run(_ctx(), PipelineState());
      expect(r.ok, isFalse);
      expect(r.error, contains('sdkmanager'));
      expect(r.error, contains('yes | sdkmanager --licenses'));
    });

    test('createIfMissing=false fails naming the manual command', () async {
      final fake = FakeRunner()
        ..reply = (_, _) => ProcessResult(0, 0, '', '');
      final step = EnsureAvdStep(
        avdName: 'gone',
        systemImage: 'sys',
        createIfMissing: false,
        runProcess: fake.call,
      );
      final r = await step.run(_ctx(), PipelineState());
      expect(r.ok, isFalse);
      expect(r.error, contains('avmmanager create avd'));
      expect(fake.sent.where((s) => s.contains('create avd')), isEmpty);
    });
  });

  group('BootEmulatorStep', () {
    test('reuses an already-running emulator for the same AVD', () async {
      final fake = FakeRunner()
        ..reply = (_, args) {
          if (args.join(' ') == 'devices -l') {
            return ProcessResult(0, 0, 'emulator-5554\tdevice\n', '');
          }
          if (args.join(' ').contains('emu avd name')) {
            return ProcessResult(0, 0, 'oka-emulator\nOK', '');
          }
          return ProcessResult(0, 0, '', '');
        };
      final step = BootEmulatorStep(avdName: 'oka-emulator', runProcess: fake.call, startProcess: (_, _) async => throw StateError('never spawn'));
      final state = PipelineState();
      final r = await step.run(_ctx(), state);
      expect(r.ok, isTrue);
      expect(state[emulatorSerial.id], 'emulator-5554');
      expect(fake.sent.where((s) => s.contains('-avd')), isEmpty,
          reason: 'no second emulator spawned');
    });

    test('boots a new emulator and waits for sys.boot_completed', () async {
      var bootPropCalls = 0;
      var spawned = false;
      final fake = FakeRunner()
        ..reply = (_, args) {
          final a = args.join(' ');
          if (a == 'devices -l') {
            return ProcessResult(
              0,
              0,
              spawned ? 'emulator-5560\tdevice\n' : '',
              '',
            );
          }
          if (a.contains('emu avd name')) {
            return ProcessResult(0, 0, 'other\nOK', '');
          }
          if (a.contains('getprop')) {
            bootPropCalls++;
            return ProcessResult(0, 0, bootPropCalls > 1 ? '1\n' : '0\n', '');
          }
          return ProcessResult(0, 0, '', '');
        };
      final step = BootEmulatorStep(
        avdName: 'oka-emulator',
        bootTimeout: const Duration(seconds: 20),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: fake.call,
        startProcess: (_, _) {
          spawned = true;
          return Future<Never>.error(StateError('fake: process handle unused'));
        },
      );
      final state = PipelineState();
      final r = await step.run(_ctx(), state);
      expect(r.ok, isTrue);
      expect(state[emulatorSerial.id], 'emulator-5560');
      expect(bootPropCalls, greaterThan(0));
    });

    test('boot timeout fails with an actionable message', () async {
      final fake = FakeRunner()
        ..reply = (_, args) {
          final a = args.join(' ');
          if (a == 'devices -l') return ProcessResult(0, 0, '', '');
          if (a.contains('getprop')) return ProcessResult(0, 0, '0', '');
          return ProcessResult(0, 0, '', '');
        };
      final step = BootEmulatorStep(
        avdName: 'oka-emulator',
        bootTimeout: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: fake.call,
      );
      final r = await step.run(_ctx(), PipelineState());
      expect(r.ok, isFalse);
      expect(r.error, contains('did not register'));
    });

    test('deviceId override waits on THAT serial', () async {
      final fake = FakeRunner()
        ..reply = (_, args) {
          final a = args.join(' ');
          if (a.contains('getprop')) return ProcessResult(0, 0, '1\n', '');
          return ProcessResult(0, 0, '', '');
        };
      final step = BootEmulatorStep(
        avdName: 'oka-emulator',
        deviceId: 'emulator-9999',
        bootTimeout: const Duration(seconds: 5),
        runProcess: fake.call,
      );
      final state = PipelineState();
      final r = await step.run(_ctx(), state);
      expect(r.ok, isTrue);
      expect(state[emulatorSerial.id], 'emulator-9999');
      expect(
        fake.sent.join(' '),
        contains('-s emulator-9999 shell getprop'),
        reason: 'multi-device: the serial must be targeted',
      );
    });
  });

  group('EmulatorTarget (typed value)', () {
    test('compiles to ensure-avd + boot-emulator and provides the serial',
        () {
      const t = EmulatorTarget(apiLevel: 35);
      final steps = t.compile(_ctx());
      expect(steps.map((final s) => s.name),
          ['ensure-avd', 'boot-emulator']);
      final pipeline = Pipeline(steps);
      expect(pipeline.validate(), isNull);
      expect(
        steps.whereType<BootEmulatorStep>().single.provides,
        contains(emulatorSerial),
      );
    });

    test('invocation args: device=<serial> override, unknown keys rejected',
        () {
      const t = EmulatorTarget();
      final applied = t.applyInvocationArgs({'device': 'emulator-5554'});
      expect(applied.deviceId, 'emulator-5554');
      expect(
        () => t.applyInvocationArgs({'bogus': '1'}),
        throwsArgumentError,
      );
    });
  });
}
