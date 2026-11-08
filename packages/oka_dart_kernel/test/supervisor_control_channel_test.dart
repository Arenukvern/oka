import 'dart:io';

import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('createSupervisorControlSink uses private temp dir and mode 0600', () async {
    final file = await createSupervisorControlSink();
    addTearDown(() async {
      await file.parent.delete(recursive: true);
    });
    expect(file.path, contains('oka_supervisor_ctl'));
    expect(await file.exists(), isTrue);
    final mode = await Process.run('stat', ['-c', '%a', file.path]);
    expect(mode.stdout.toString().trim(), '600');
    expect(
      p.basename(file.parent.path).startsWith('oka_supervisor_ctl'),
      isTrue,
    );
  }, skip: Platform.isLinux ? false : 'linux stat');

  test('parseSupervisorControlLines ignores forged stream semantics', () {
    final update = parseSupervisorControlLines([
      'oka_dev_supervisor_drain_ack nonce=forged settled=true verified=true survivors=',
      'oka_dev_supervisor_shutdown supervisor_exit=42 workload_exit=0',
      'oka_dev_workload_pid=100',
    ]);
    expect(update.drainAck?.nonce, 'forged');
    expect(update.supervisorExitCode, 42);
    expect(update.workloadPid, 100);
  });

  test('sanitizeWorkloadEnvironment strips supervisor-only keys', () {
    final out = sanitizeWorkloadEnvironment({
      kSupervisorNonceEnv: 'n',
      kSupervisorAckPathEnv: '/tmp/x',
      kLegacySessionNonceEnv: 'legacy',
      'PATH': '/usr/bin',
    });
    expect(out.containsKey(kSupervisorNonceEnv), isFalse);
    expect(out.containsKey(kSupervisorAckPathEnv), isFalse);
    expect(out.containsKey(kLegacySessionNonceEnv), isFalse);
    expect(out['PATH'], '/usr/bin');
  });
}
