import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain_receipt.dart';
import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('createSupervisorControlSink uses private temp dir mode 0700 and file 0600', () async {
    final file = await createSupervisorControlSink();
    addTearDown(() async {
      await file.parent.delete(recursive: true);
    });
    expect(p.basename(file.parent.path).startsWith('oka_supervisor_ctl_'), isTrue);
    final dirMode = await Process.run('stat', ['-c', '%a', file.parent.path]);
    final fileMode = await Process.run('stat', ['-c', '%a', file.path]);
    expect(dirMode.stdout.toString().trim(), '700');
    expect(fileMode.stdout.toString().trim(), '600');
  }, skip: Platform.isLinux ? false : 'linux stat');

  test(
    'workload spawn with includeParentEnvironment false drops supervisor keys',
    () async {
      final file = await createSupervisorControlSink();
      addTearDown(() async {
        await file.parent.delete(recursive: true);
      });
      final helper = File('${Directory.systemTemp.path}/oka_ctl_env_probe.dart');
      addTearDown(() async {
        if (await helper.exists()) await helper.delete();
      });
      await helper.writeAsString('''
import 'dart:convert';
import 'dart:io';
void main() {
  const deny = [
    '$kSupervisorNonceEnv',
    '$kSupervisorAckPathEnv',
    '$kLegacySessionNonceEnv',
  ];
  for (final key in deny) {
    if (Platform.environment.containsKey(key)) {
      stderr.writeln('leaked:\$key');
      exit(3);
    }
  }
  if (Platform.environment['PATH']?.isNotEmpty != true) {
    stderr.writeln('missing PATH');
    exit(4);
  }
  stdout.writeln('ok');
}
''');
      final parent = Map<String, String>.from(Platform.environment);
      parent[kSupervisorNonceEnv] = 'leak-nonce';
      parent[kSupervisorAckPathEnv] = file.path;
      parent[kLegacySessionNonceEnv] = 'leak-legacy';
      final child = await Process.start(
        Platform.executable,
        [helper.path],
        environment: workloadProcessEnvironment(parent),
        includeParentEnvironment: false,
      );
      final out = await child.stdout.transform(utf8.decoder).join();
      final err = await child.stderr.transform(utf8.decoder).join();
      expect(await child.exitCode, 0, reason: err);
      expect(out.trim(), 'ok');
    },
    skip: Platform.isLinux ? false : 'linux spawn',
  );

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

  test('parseSupervisorControlLines collects drain diagnostics', () {
    final diag = SubreaperDrainReceipt(
      phase: 'survivors',
      remainingMs: 50,
      observations: const ['9:Z:sleep'],
      errors: const ['kill_timeout'],
    ).toControlLine();
    final update = parseSupervisorControlLines([
      diag,
      'oka_dev_supervisor_drain_ack nonce=n settled=false verified=false survivors=9',
    ]);
    expect(update.drainDiags, hasLength(1));
    expect(update.drainDiags.first.phase, 'survivors');
    expect(update.drainDiags.first.observations, ['9:Z:sleep']);
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
