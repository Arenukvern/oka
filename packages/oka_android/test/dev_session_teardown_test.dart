import 'dart:io';

import 'package:oka_android/src/dev/adb_tool.dart';
import 'package:oka_android/src/dev/dev_session_teardown.dart';
import 'package:test/test.dart';

void main() {
  group('adbForwardRemoveArgs', () {
    test('serial-scoped single port remove', () {
      expect(
        adbForwardRemoveArgs(hostPort: 34381, serial: 'emulator-5554'),
        ['-s', 'emulator-5554', 'forward', '--remove', 'tcp:34381'],
      );
    });
  });

  group('parseAdbForwardList', () {
    test('parses host:device tcp forwards', () {
      const out = '''
List of all forwards
\temulator-5554 tcp:34381 tcp:35699
\temulator-5554 tcp:35059 tcp:35699
''';
      final entries = parseAdbForwardList(out);
      expect(entries, hasLength(2));
      expect(entries[0].serial, 'emulator-5554');
      expect(entries[0].hostLocalPort, 34381);
      expect(entries[0].deviceRemotePort, 35699);
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
      final calls = <List<String>>[];
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        runAdb: (adb, args) async {
          calls.add(args);
          if (args.contains('--list')) {
            return ProcessResult(
              0,
              0,
              'emulator-5554 tcp:34381 tcp:99999\n',
              '',
            );
          }
          fail('must not remove when remote mismatches');
        },
        listForwards: (adb, serial) async => parseAdbForwardList(
          'emulator-5554 tcp:34381 tcp:99999\n',
        ),
      );
      expect(report.removed, isFalse);
      expect(report.refusedConcurrencyMismatch, isTrue);
      expect(calls, isEmpty);
    });

    test('removes only when list matches creation triplet', () async {
      final calls = <List<String>>[];
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        listForwards: (adb, serial) async => parseAdbForwardList(
          'emulator-5554 tcp:34381 tcp:35699\n',
        ),
        runAdb: (adb, args) async {
          calls.add(args);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(report.removed, isTrue);
      expect(
        calls.single,
        ['-s', 'emulator-5554', 'forward', '--remove', 'tcp:34381'],
      );
    });

    test('skips remove when forward already absent', () async {
      final report = await releaseSessionCreatedForward(
        forward,
        adbPath: '/adb',
        listForwards: (adb, serial) async => const [],
        runAdb: (adb, args) async => fail('no adb when absent'),
      );
      expect(report.attempted, isFalse);
      expect(report.alreadyAbsent, isTrue);
    });

    test('does not touch unrelated local port on same device', () async {
      final other = DevSessionCreatedForward(
        deviceSerial: 'emulator-5554',
        hostLocalPort: 35059,
        deviceRemotePort: 35699,
        recordedAt: DateTime.utc(2026, 11, 8),
      );
      final report = await releaseSessionCreatedForward(
        other,
        adbPath: '/adb',
        listForwards: (adb, serial) async => parseAdbForwardList(
          'emulator-5554 tcp:34381 tcp:35699\n'
          'emulator-5554 tcp:35059 tcp:35699\n',
        ),
        runAdb: (adb, args) async {
          if (args.contains('34381')) fail('must not remove 34381');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(report.removed, isTrue);
    });
  });

  group('waitDevicePackageAbsent', () {
    test('succeeds when pidof returns empty', () async {
      var polls = 0;
      final report = await waitDevicePackageAbsent(
        adbPath: '/adb',
        deviceSerial: 'emu',
        packageName: 'com.example.app',
        pollInterval: Duration.zero,
        timeout: const Duration(milliseconds: 50),
        runAdb: (adb, args) async {
          polls++;
          return ProcessResult(0, 1, '', ''); // pidof: not running
        },
      );
      expect(report.absentObserved, isTrue);
      expect(polls, greaterThan(0));
      expect(report.proven, isFalse);
    });
  });

  group('DevSessionTeardownReport honesty', () {
    test('proven flags stay false even when actions succeed', () {
      const report = DevSessionTeardownReport(
        forward: ForwardReleaseAction(removed: true, attempted: true),
        appStop: AppStopAction(
          rpcOk: true,
          duration: Duration(milliseconds: 73),
        ),
      );
      expect(report.provenForwardRemoved, isFalse);
      expect(report.provenDeviceAppAbsent, isFalse);
      expect(report.provenPhysicalSettlement, isFalse);
      expect(report.forward?.removed, isTrue);
    });
  });
}
