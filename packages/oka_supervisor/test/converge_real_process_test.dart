import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

/// Real-process end-to-end (dev-only `oka_core` dep, never published):
/// converge a genuine `/bin/sh` service through `LeasedProcessProvider`,
/// prove the second pass converges to `ready`, and prove a crashing
/// command climbs the budget ladder to `giveUp`.
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-supervisor-real');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('converges a real service to ready and keeps it running', () async {
    final leases = ProcessLeaseRegistry.forProject(temp.path);
    final provider = LeasedProcessProvider(
      leaseId: 'oka-supervisor-demo',
      command: const ProcessCommand('/bin/sh', [
        '-c',
        'echo oka-supervisor-ready; sleep 60',
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
          id: 'demo',
          providerName: 'sh',
          readiness: HandshakeLine(
            pattern: 'oka-supervisor-ready',
            budget: Duration(seconds: 10),
          ),
        ),
      ],
    );

    final first = await supervisor.converge(
      desired: desired,
      factory: (final name) => provider,
    );
    expect(first.started, 1);
    final record = supervisor.registry.read(supervisor.scope, 'demo');
    expect(record, isNotNull);
    expect(record!.pid, isNotNull);
    expect(record.identityToken, isNotNull);

    final second = await supervisor.converge(
      desired: desired,
      factory: (final name) => provider,
    );
    expect(second.plan.actions, isEmpty);
    expect(second.plan.findings.single.code, 'ready');

    // Cleanup: stop through the provider with the recorded identity.
    final stop = await provider.stop(
      ResourceRef(
        componentId: 'demo',
        handle: record.handle!,
        pid: record.pid,
        identityToken: record.identityToken,
      ),
      grace: const Duration(seconds: 2),
    );
    expect(stop.stopped, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a crashing command climbs the budget ladder to giveUp', () async {
    final leases = ProcessLeaseRegistry.forProject(temp.path);
    final provider = LeasedProcessProvider(
      leaseId: 'oka-supervisor-crash',
      command: const ProcessCommand('/bin/sh', ['-c', 'exit 7']),
      registry: leases,
    );
    final supervisor = Supervisor(
      projectRoot: temp.path,
      registry: MachineRegistry(root: '${temp.path}/supervisor'),
    );
    const desired = DesiredState(
      specs: [
        ComponentSpec(
          id: 'crasher',
          providerName: 'sh',
          readiness: HandshakeLine(
            pattern: 'never-matches',
            budget: Duration(milliseconds: 500),
          ),
          policy: SupervisionPolicy(maxRestarts: 1),
        ),
      ],
    );
    ResourceProvider factory(final String name) => provider;

    final first = await supervisor.converge(desired: desired, factory: factory);
    expect(first.failedStarts, 1);
    expect(
      supervisor.registry.read(supervisor.scope, 'crasher')!.lastRun,
      'failed',
    );

    final second = await supervisor.converge(
      desired: desired,
      factory: factory,
    );
    expect(second.failedStarts, 1);
    expect(
      supervisor.registry.read(supervisor.scope, 'crasher')!.restartCount,
      1,
    );

    final third = await supervisor.converge(desired: desired, factory: factory);
    expect(third.plan.actions, isEmpty);
    expect(third.plan.findings.map((final f) => f.code), contains('giveUp'));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
