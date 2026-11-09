import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';
import 'package:test/test.dart';

import 'linux_proc_reader_fixtures.dart';

int _linuxSelfPid() =>
    int.parse(File('/proc/self/stat').readAsStringSync().split(' ').first);

void main() {
  test(
    'production drain fails closed when proc stat omitted for direct adoptee',
    () async {
      final supervisor = _linuxSelfPid();
      final child = await Process.start('sleep', ['120']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final result = await drainSubreaperAdoptees(
        supervisorPid: supervisor,
        procStatReader: DenyLinuxProcStatReader(denyPid: child.pid),
        budget: const Duration(seconds: 2),
        poll: const Duration(milliseconds: 40),
      );
      expect(result.verified, isFalse, reason: result.notes.join('; '));
      expect(
        result.notes,
        anyElement(contains('proc scan:')),
      );
    },
    skip: Platform.isLinux ? false : 'linux drain',
  );

  test(
    'adoptee revealed after empty proc scans is terminated or unverified',
    () async {
      final supervisor = _linuxSelfPid();
      const liveness = HostProcessLiveness();
      final child = await Process.start('sleep', ['120']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final result = await drainSubreaperAdoptees(
        supervisorPid: supervisor,
        procStatReader: HidePidListLinuxProcStatReader(hidePid: child.pid),
        budget: const Duration(seconds: 2),
        poll: const Duration(milliseconds: 60),
      );
      final childAlive = await liveness.isAlive(child.pid);
      if (childAlive) {
        expect(result.verified, isFalse, reason: result.notes.join('; '));
      } else {
        expect(result.verified, isTrue, reason: result.notes.join('; '));
      }
    },
    skip: Platform.isLinux ? false : 'linux drain',
  );

  test(
    'budget exhaustion before verified pass is unverified',
    () async {
      final supervisor = _linuxSelfPid();
      final result = await drainSubreaperAdoptees(
        supervisorPid: supervisor,
        procStatReader: SlowLinuxProcStatReader(
          perStatDelay: const Duration(milliseconds: 8),
        ),
        budget: const Duration(milliseconds: 40),
        poll: const Duration(milliseconds: 10),
      );
      expect(result.verified, isFalse);
      expect(
        result.notes.any(
          (n) => n.contains('timed out') || n.contains('budget'),
        ),
        isTrue,
      );
    },
    skip: Platform.isLinux ? false : 'linux drain',
  );
}
