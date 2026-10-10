import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';

/// Runnable demo: declare one real service, converge it to running,
/// watch a converge report `ready`, crash it, watch a converge restart
/// it, converge again, and show the facts.
///
///   cd packages/oka_supervisor && dart run example/supervise_demo.dart
///
/// Cleanup is automatic (the service is stopped and the temp dir removed).
Future<void> main() async {
  final work = await Directory.systemTemp.createTemp('oka-supervisor-demo');
  final registry = MachineRegistry(root: '${work.path}/supervisor');
  final supervisor = Supervisor(projectRoot: work.path, registry: registry);
  final facts = JsonlEvidenceSink('${work.path}/facts.jsonl');
  final leases = ProcessLeaseRegistry.forProject(work.path);

  // The provider owns spawn/probe/stop mechanics; the supervisor owns
  // desire, diff, and decision. `exec sleep` keeps the tree single-process
  // so the crash below is a clean kill.
  final provider = LeasedProcessProvider(
    leaseId: 'demo-service',
    command: const ProcessCommand('/bin/sh', [
      '-c',
      'echo demo-ready; exec sleep 30',
    ]),
    registry: leases,
  );

  // `service` (desired running) is the default shape; the budget is
  // non-default so the demo shows the knobs.
  const policy = SupervisionPolicy(maxRestarts: 5);
  const desired = DesiredState(
    specs: [
      ComponentSpec(
        id: 'demo-service',
        providerName: 'sh',
        readiness: HandshakeLine(
          pattern: 'demo-ready',
          budget: Duration(seconds: 10),
        ),
        policy: policy,
      ),
    ],
  );
  ResourceProvider factory(final String name) => provider;

  Future<String> converge() => supervisor
      .converge(desired: desired, factory: factory, evidence: facts)
      .then((final report) => report.describe());

  // 1. Desired but absent → converge starts it.
  // 2. Running → converge observes and only reports.
  final started = await converge();
  final converged = await converge();
  stdout
    ..writeln('— converge #1 (start) —\n$started')
    ..writeln('— converge #2 (converged) —\n$converged');

  // 3. Simulate a crash. The next converge restarts within budget.
  final record = supervisor.registry.read(supervisor.scope, 'demo-service')!;
  Process.killPid(record.pid!, ProcessSignal.sigkill);
  final restarted = await converge();
  stdout
    ..writeln('— killed pid ${record.pid}; converge #3 (restart) —')
    ..writeln(restarted);

  // 4. Back to ready.
  final ready = await converge();
  stdout.writeln('— converge #4 (converged again) —\n$ready');

  // 5. Teardown through the provider with the recorded identity, and show
  // the fact stream — the same envelope every consumer reads.
  final after = supervisor.registry.read(supervisor.scope, 'demo-service')!;
  await provider.stop(
    ResourceRef(
      componentId: 'demo-service',
      handle: after.handle!,
      pid: after.pid,
      identityToken: after.identityToken,
    ),
    grace: const Duration(seconds: 2),
  );
  await facts.close();

  final factsPath = '${work.path}/facts.jsonl';
  stdout
    ..writeln('— facts ($factsPath) —')
    ..writeln(File(factsPath).readAsStringSync().trim());
  await work.delete(recursive: true);
}
