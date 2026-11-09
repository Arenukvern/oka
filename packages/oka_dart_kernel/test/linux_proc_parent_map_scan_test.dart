import 'dart:io';

import 'package:oka_dart_kernel/src/gate/linux_proc_process_tree_probe.dart';
import 'package:test/test.dart';

import 'linux_proc_reader_fixtures.dart';

void main() {
  test('parseLinuxProcStatPpid uses last closing paren', () {
    const stat =
        '42 (foo) (bar)) S 41 42 42 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0';
    expect(parseLinuxProcStatPpid(stat), 41);
  });

  test(
    'host scan is complete and includes a real child process',
    () async {
      final child = await Process.start('sleep', ['90']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final scan = await scanLinuxProcParentMap(
        deadline: DateTime.now().add(const Duration(seconds: 2)),
      );
      expect(scan.timedOut, isFalse);
      expect(scan.errors, isEmpty);
      expect(scan.complete, isTrue);
      expect(scan.entries.containsKey(child.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux /proc',
  );

  test(
    'denying stat for a live owned pid marks scan incomplete',
    () async {
      final child = await Process.start('sleep', ['90']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final scan = await scanLinuxProcParentMap(
        deadline: DateTime.now().add(const Duration(seconds: 2)),
        reader: DenyLinuxProcStatReader(denyPid: child.pid),
      );
      expect(scan.complete, isFalse);
      expect(scan.errors, isNotEmpty);
      expect(
        scan.errors,
        anyElement(contains('EACCES injected')),
      );
    },
    skip: Platform.isLinux ? false : 'linux /proc',
  );

  test(
    'scan respects deadline under slow stat reads',
    () async {
      final scan = await scanLinuxProcParentMap(
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        reader: SlowLinuxProcStatReader(
          perStatDelay: const Duration(milliseconds: 5),
        ),
      );
      expect(scan.timedOut, isTrue);
      expect(scan.complete, isFalse);
    },
    skip: Platform.isLinux ? false : 'linux /proc',
  );
}
