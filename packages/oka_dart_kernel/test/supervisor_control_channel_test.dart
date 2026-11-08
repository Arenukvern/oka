import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';
import 'package:test/test.dart';

void main() {
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
