import 'dart:convert';
import 'dart:io';
import 'package:oka_core/oka_core.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  test(
    'fresh runner observes surviving service after supervisor SIGKILL',
    () async {
      final temp = await Directory.systemTemp.createTemp('oka-host-crash');
      final evidence = '${temp.path}/evidence';
      final registry = ProcessLeaseRegistry.forProject(evidence);
      try {
        final run = await runBoundedProcess(Platform.resolvedExecutable, [
          File('tool/host_crash_dogfood.dart').absolute.path,
          evidence,
        ], timeout: const Duration(minutes: 2));
        expect(run.ok, isTrue, reason: '${run.stdout}\n${run.stderr}');
        final host =
            jsonDecode(
                  File('$evidence/host-crash-result.json').readAsStringSync(),
                )
                as Map;
        expect(host['serviceSurvivedRunnerKill'], isTrue);
        expect(host['cleanupVerified'], isTrue);
        final recovery =
            jsonDecode(File('$evidence/result.json').readAsStringSync()) as Map;
        final stages = recovery['stages'] as List;
        final observed = stages.first as Map;
        expect(observed['stage'], 'observe');
        expect(observed['started'], 0);
        expect(observed['restarted'], 0);
        expect(observed['findings'], ['ready']);
        expect(await registry.read('service'), isNull);
      } finally {
        final lease = await registry.read('service');
        if (lease != null) {
          final provider = LeasedProcessProvider(
            leaseId: 'service',
            command: const ProcessCommand('unused'),
            registry: registry,
          );
          await provider.stop(
            ResourceRef(
              componentId: 'service',
              handle: 'service',
              pid: lease.pid,
              identityToken: lease.identity[processLeasePidTokenKey],
            ),
            grace: const Duration(milliseconds: 200),
          );
        }
        if (await registry.read('service') == null) {
          await temp.delete(recursive: true);
        }
      }
    },
    skip: Platform.isWindows ? 'POSIX SIGKILL recovery trial' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
