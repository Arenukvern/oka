// Local callback parameters stay compatible with Dart 3.13.
// ignore_for_file: prefer_final_parameters
import 'dart:async';
import 'dart:io';
import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real service crash restarts within budget, then owned stop cleans lease',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'oka-service-lifecycle',
      );
      final leases = ProcessLeaseRegistry.forProject(temp.path);
      final fixture = File('${temp.path}/service.dart')
        ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.writeln('ready'); await stdout.flush();
  while (!File(args[0]).existsSync()) await Future<void>.delayed(const Duration(milliseconds:10));
  exit(7);
}
''');
      final crash = File('${temp.path}/crash');
      final provider = LeasedProcessProvider(
        leaseId: 'service',
        command: ProcessCommand(Platform.resolvedExecutable, [
          fixture.path,
          crash.path,
        ]),
        registry: leases,
      );
      final supervisor = Supervisor(
        projectRoot: temp.path,
        registry: MachineRegistry(root: '${temp.path}/supervisor'),
      );
      const desired = DesiredState(
        specs: [
          ComponentSpec(
            id: 'service',
            providerName: 'process',
            readiness: HandshakeLine(
              pattern: 'ready',
              budget: Duration(seconds: 5),
            ),
            policy: SupervisionPolicy(maxRestarts: 1),
          ),
        ],
      );
      ResourceRef? owned;
      ResourceProvider factory(String name) => provider;
      Future<void> waitDead(int pid) async {
        final clock = Stopwatch()..start();
        while (await const HostProcessLiveness().isAlive(pid)) {
          if (clock.elapsed > const Duration(seconds: 5)) {
            throw TimeoutException('owned process did not exit');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      ResourceRef reference() {
        final record = supervisor.registry.read(supervisor.scope, 'service')!;
        return ResourceRef(
          componentId: 'service',
          handle: record.handle!,
          pid: record.pid,
          identityToken: record.identityToken,
        );
      }

      try {
        final start = await supervisor.converge(
          desired: desired,
          factory: factory,
        );
        expect(start.started, 1);
        owned = reference();
        final observed = await supervisor.converge(
          desired: desired,
          factory: factory,
          apply: false,
        );
        expect(observed.plan.actions, isEmpty);
        expect(observed.plan.findings.single.code, 'ready');
        crash.writeAsStringSync('crash');
        await waitDead(owned.pid!);
        crash.deleteSync();
        final restarted = await supervisor.converge(
          desired: desired,
          factory: factory,
        );
        expect(restarted.restarted, 1);
        final replacement = reference();
        expect(replacement.pid, isNot(owned.pid));
        owned = replacement;
        expect(
          supervisor.registry.read(supervisor.scope, 'service')!.restartCount,
          1,
        );
        final stop = await provider.stop(
          owned,
          grace: const Duration(milliseconds: 200),
        );
        expect(stop.stopped, isTrue);
        await waitDead(owned.pid!);
        expect(await leases.read('service'), isNull);
        final exhausted = await supervisor.converge(
          desired: desired,
          factory: factory,
        );
        expect(exhausted.plan.actions, isEmpty);
        expect(exhausted.plan.findings.map((f) => f.code), contains('giveUp'));
      } finally {
        if (owned != null) {
          await provider.stop(owned, grace: const Duration(milliseconds: 200));
        }
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
