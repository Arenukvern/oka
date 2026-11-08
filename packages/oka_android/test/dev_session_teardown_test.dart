import 'dart:io';

import 'package:oka_android/src/dev/dev_session_teardown.dart';
import 'package:oka_android/src/dev/dev_session_teardown_budget.dart';
import 'package:test/test.dart';

const _remove34381 = <String>[
  '-s',
  'emulator-5554',
  'forward',
  '--remove',
  'tcp:34381',
];

void main() {
  group('devSessionTeardownBudget', () {
    test('rejects work after overall budget elapsed', () async {
      final budget = DevSessionTeardownBudget(
        total: Duration.zero,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(
        () => budget.run(() => Future<int>.value(1), cap: const Duration(seconds: 1)),
        throwsA(isA<DevSessionTeardownBudgetExhausted>()),
      );
    });
  });

  group('listAdbForwards', () {
    test('nonzero exit is list failure not absent forward', () async {
      final listed = await listAdbForwards(
        adbPath: '/adb',
        runAdb: (adb, args) async => ProcessResult(0, 127, '', 'offline'),
      );
      expect(listed.ok, isFalse);
      final forward = DevSessionCreatedForward(
        deviceSerial: 'emulator-5554',
        hostLocalPort: 34381,
        deviceRemotePort: 35699,
        recordedAt: DateTime.utc(2026, 11, 8),
      );
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        listForwards: (adb, serial) async => listed,
        runAdb: (adb, args) async => fail('remove must not run'),
      );
      expect(report.listFailed, isTrue);
      expect(report.alreadyAbsent, isFalse);
      expect(report.removed, isFalse);
    });
  });

  group('releaseSessionCreatedForward', () {
    final forward = DevSessionCreatedForward(
      deviceSerial: 'emulator-5554',
      hostLocalPort: 34381,
      deviceRemotePort: 35699,
      recordedAt: DateTime.utc(2026, 11, 8),
    );

    test('refuses remove when local port maps to different remote', () async {
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        listForwards: (adb, serial) async => ForwardListAction(
          ok: true,
          entries: parseAdbForwardList(
            'emulator-5554 tcp:34381 tcp:99999\n',
          ),
        ),
        runAdb: (adb, args) async => fail('must not remove when remote mismatches'),
      );
      expect(report.removed, isFalse);
      expect(report.refusedConcurrencyMismatch, isTrue);
    });

    test('removes only exact creation triplet', () async {
      final calls = <List<String>>[];
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        listForwards: (adb, serial) async => ForwardListAction(
          ok: true,
          entries: parseAdbForwardList(
            'emulator-5554 tcp:34381 tcp:35699\n',
          ),
        ),
        runAdb: (adb, args) async {
          calls.add(args);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(report.removed, isTrue);
      expect(calls.single, _remove34381);
    });

    test('does not remove unrelated local port', () async {
      final other = DevSessionCreatedForward(
        deviceSerial: 'emulator-5554',
        hostLocalPort: 35059,
        deviceRemotePort: 35699,
        recordedAt: DateTime.utc(2026, 11, 8),
      );
      final calls = <List<String>>[];
      final report = await releaseSessionCreatedForward(
        other,
        adbPath: '/adb',
        listForwards: (adb, serial) async => ForwardListAction(
          ok: true,
          entries: parseAdbForwardList(
            'emulator-5554 tcp:34381 tcp:35699\n'
            'emulator-5554 tcp:35059 tcp:35699\n',
          ),
        ),
        runAdb: (adb, args) async {
          calls.add(args);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(report.removed, isTrue);
      expect(
        calls.single,
        ['-s', 'emulator-5554', 'forward', '--remove', 'tcp:35059'],
      );
      expect(calls.any((a) => a == _remove34381), isFalse);
    });
  });

  group('waitDevicePackageAbsent', () {
    test('empty stdout with nonzero adb exit is not absent', () async {
      final report = await waitDevicePackageAbsent(
        adbPath: '/adb',
        deviceSerial: 'emu',
        packageName: 'com.example.app',
        pollInterval: Duration.zero,
        timeout: const Duration(milliseconds: 10),
        runAdb: (adb, args) async => ProcessResult(0, 1, '', 'device offline'),
      );
      expect(report.absentObserved, isFalse);
      expect(report.adbFailed, isTrue);
    });

    test('absent only when pidof exit zero and empty', () async {
      final report = await waitDevicePackageAbsent(
        adbPath: '/adb',
        deviceSerial: 'emu',
        packageName: 'com.example.app',
        pollInterval: Duration.zero,
        timeout: const Duration(milliseconds: 50),
        runAdb: (adb, args) async => ProcessResult(0, 0, '', ''),
      );
      expect(report.absentObserved, isTrue);
      expect(report.proven, isFalse);
    });

    test('times out when pid keeps reporting', () async {
      final report = await waitDevicePackageAbsent(
        adbPath: '/adb',
        deviceSerial: 'emu',
        packageName: 'com.example.app',
        pollInterval: Duration.zero,
        timeout: const Duration(milliseconds: 1),
        runAdb: (adb, args) async => ProcessResult(0, 0, '4242', ''),
      );
      expect(report.timedOut, isTrue);
      expect(report.absentObserved, isFalse);
    });
  });

  group('DevSessionTeardownReport', () {
    test('proven flags stay false', () {
      const report = DevSessionTeardownReport(
        forward: ForwardReleaseAction(removed: true, attempted: true),
        pidofWait: PidofWaitAction(
          attempted: true,
          absentObserved: true,
          proven: false,
        ),
      );
      expect(report.provenPhysicalSettlement, isFalse);
      expect(report.actionsSucceeded, isTrue);
    });

    test('cleanup fails when pidof never absent on quit', () {
      const report = DevSessionTeardownReport(
        appStop: AppStopAction(
          rpcOk: true,
          duration: Duration(milliseconds: 73),
        ),
        pidofWait: PidofWaitAction(
          attempted: true,
          absentObserved: false,
          proven: false,
          lastPidOutput: '2414',
          timedOut: true,
        ),
      );
      expect(report.actionsSucceeded, isFalse);
    });
  });
}
