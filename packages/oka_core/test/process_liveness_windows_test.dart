import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

const _machineId = '01234567-89ab-cdef-0123-456789abcdef';
const _bootTime = '2025-04-03T02:01:00.0000000Z';
const _startTime = '2025-04-03T02:02:03.4567890Z';

String _aliveOutput({
  final String machineId = _machineId,
  final String bootTime = _bootTime,
  final String startTime = _startTime,
}) => 'alive|$machineId|$bootTime|$startTime\n';

void main() {
  group('Windows process probe output parser', () {
    test('builds an identity token from machine, boot, and start identity', () {
      final snapshot = parseWindowsProcessProbeOutput(_aliveOutput());

      expect(snapshot, isNotNull);
      expect(snapshot!.isAlive, isTrue);
      expect(
        snapshot.identityToken,
        'windows|$_machineId|$_bootTime|$_startTime',
      );
    });

    test('host reinstall and reboot identity changes invalidate the token', () {
      final original = parseWindowsProcessProbeOutput(_aliveOutput())!;
      final anotherHost = parseWindowsProcessProbeOutput(
        _aliveOutput(machineId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'),
      )!;
      final anotherBoot = parseWindowsProcessProbeOutput(
        _aliveOutput(bootTime: '2025-04-03T02:03:00.0000000Z'),
      )!;

      expect(anotherHost.identityToken, isNot(original.identityToken));
      expect(anotherBoot.identityToken, isNot(original.identityToken));
    });

    test('missing PID is distinct from malformed or incomplete identity', () {
      final snapshot = parseWindowsProcessProbeOutput(
        'missing|$_machineId|$_bootTime|\n',
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.isAlive, isFalse);
      expect(snapshot.identityToken, isNull);
    });

    test('fails closed on malformed records and unverifiable identity', () {
      for (final output in [
        '',
        'alive|$_machineId|$_bootTime|\n',
        'alive|not-a-guid|$_bootTime|$_startTime\n',
        'alive|$_machineId|not-a-time|$_startTime\n',
        'alive|$_machineId|$_bootTime|$_startTime|extra\n',
        'alive|$_machineId|2025-04-03T02:01:00.0000000|$_startTime\n',
        'missing|$_machineId|$_bootTime|unexpected\n',
        'unknown|$_machineId|$_bootTime|$_startTime\n',
      ]) {
        expect(parseWindowsProcessProbeOutput(output), isNull, reason: output);
      }
    });
  });

  group('Windows process command seam', () {
    test(
      'uses PowerShell/CIM and returns only a verified process identity',
      () async {
        String? executable;
        List<String>? arguments;
        final liveness = WindowsProcessLiveness(
          commandRunner: (final command, final args) async {
            executable = command;
            arguments = args;
            return ProcessResult(1, 0, _aliveOutput(), '');
          },
        );

        expect(await liveness.isAlive(321), isTrue);
        expect(
          await liveness.identityToken(321),
          'windows|$_machineId|$_bootTime|$_startTime',
        );
        expect(executable, 'powershell.exe');
        expect(arguments, contains('-NoProfile'));
        expect(arguments, contains('-NonInteractive'));
        expect(
          arguments!.last,
          contains(
            r'Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pidValue"',
          ),
        );
        expect(arguments!.last, contains('Win32_OperatingSystem'));
        expect(arguments!.last, contains('MachineGuid'));
      },
    );

    test(
      'a validated missing result is not live and has no identity',
      () async {
        final liveness = WindowsProcessLiveness(
          commandRunner: (_, _) async =>
              ProcessResult(1, 0, 'missing|$_machineId|$_bootTime|\n', ''),
        );

        expect(await liveness.isAlive(321), isFalse);
        expect(await liveness.identityToken(321), isNull);
      },
    );

    test('command and parse failures never report the PID as alive', () async {
      final failedCommand = WindowsProcessLiveness(
        commandRunner: (_, _) async =>
            ProcessResult(1, 1, '', 'CIM unavailable'),
      );
      final malformedOutput = WindowsProcessLiveness(
        commandRunner: (_, _) async =>
            ProcessResult(1, 0, 'alive|$_machineId|$_bootTime|\n', ''),
      );

      await expectLater(
        failedCommand.isAlive(321),
        throwsA(isA<ProcessException>()),
      );
      await expectLater(
        malformedOutput.isAlive(321),
        throwsA(isA<FormatException>()),
      );
    });

    test('probe script only interpolates a positive numeric PID', () {
      final script = windowsProcessProbeScript(321);

      expect(script, contains(r'$pidValue = 321'));
      expect(script, contains(r'ProcessId = $pidValue'));
      expect(() => windowsProcessProbeScript(0), throwsArgumentError);
    });
  });

  test(
    'HostProcessLiveness uses a real Windows process when running there',
    () async {
      const liveness = HostProcessLiveness();
      expect(await liveness.isAlive(pid), isTrue);
      expect(await liveness.identityToken(pid), isNotNull);
    },
    skip: !Platform.isWindows,
  );
}
