// Local callback parameters stay compatible with Dart 3.13.
// ignore_for_file: prefer_final_parameters
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';

/// Real service lifecycle with retained facts and verified owned teardown.
/// Run from this package: dart run tool/service_lifecycle_dogfood.dart NEW_OUTPUT
Future<void> main(List<String> args) async {
  final birth = args.length == 2 && args.first == '--birth';
  final recover = args.length == 2 && args.first == '--recover';
  if (args.length != 1 && !birth && !recover) {
    throw ArgumentError('NEW_OUTPUT or --birth/--recover OUTPUT required');
  }
  final output = Directory(args.last).absolute;
  if (output.existsSync() && !recover) {
    throw StateError('refusing existing evidence directory');
  }
  if (recover && !File('${output.path}/birth.json').existsSync()) {
    throw StateError('recovery requires this fixture birth receipt');
  }
  output.createSync(recursive: true);
  final facts = JsonlEvidenceSink('${output.path}/facts.jsonl');
  final leases = ProcessLeaseRegistry.forProject(output.path);
  final fixture = File('${output.path}/service.dart')
    ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.writeln('ready'); await stdout.flush();
  while (!File(args[0]).existsSync()) await Future<void>.delayed(const Duration(milliseconds:10));
  exit(7);
}
''');
  final crash = File('${output.path}/crash');
  final provider = LeasedProcessProvider(
    leaseId: 'service',
    command: ProcessCommand(Platform.resolvedExecutable, [
      fixture.path,
      crash.path,
    ]),
    registry: leases,
  );
  final supervisor = Supervisor(
    projectRoot: output.path,
    registry: MachineRegistry(root: '${output.path}/supervisor'),
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
  final stages = <Map<String, Object?>>[];
  // Assertions describe observed results, not configuration options.
  // ignore: avoid_positional_boolean_parameters
  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

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
    final r = supervisor.registry.read(supervisor.scope, 'service')!;
    return ResourceRef(
      componentId: 'service',
      handle: r.handle!,
      pid: r.pid,
      identityToken: r.identityToken,
    );
  }

  Future<ConvergenceReport> pass(String name, {bool apply = true}) async {
    final report = await supervisor.converge(
      desired: desired,
      factory: (_) => provider,
      evidence: facts,
      apply: apply,
    );
    File('${output.path}/$name.txt').writeAsStringSync(report.describe());
    stages.add({
      'stage': name,
      'started': report.started,
      'restarted': report.restarted,
      'failedStarts': report.failedStarts,
      'findings': [for (final f in report.plan.findings) f.code],
    });
    return report;
  }

  var passed = false;
  String? failure;
  var cleanupVerified = false;
  try {
    if (!recover) {
      final start = await pass('start');
      require(start.started == 1, 'start failed');
    }
    owned = reference();
    if (birth) {
      await facts.close();
      File('${output.path}/birth.json').writeAsStringSync(
        jsonEncode({
          'runnerPid': pid,
          'servicePid': owned.pid,
          'serviceIdentityToken': owned.identityToken,
        }),
      );
      // The controlling dogfood intentionally SIGKILLs this runner.
      await Completer<void>().future;
    }
    if (recover) {
      final original =
          jsonDecode(File('${output.path}/birth.json').readAsStringSync())
              as Map;
      require(
        owned.pid == original['servicePid'] &&
            owned.identityToken == original['serviceIdentityToken'],
        'recovery replaced the service before observation',
      );
    }
    final observation = await pass('observe', apply: false);
    require(
      observation.plan.actions.isEmpty &&
          observation.plan.findings.single.code == 'ready',
      'observation changed state or was not ready',
    );
    crash.writeAsStringSync('crash');
    await waitDead(owned.pid!);
    crash.deleteSync();
    final restart = await pass('restart');
    final replacement = reference();
    final previousPid = owned.pid;
    owned = replacement;
    require(
      restart.restarted == 1 && replacement.pid != previousPid,
      'restart failed',
    );
    require(
      supervisor.registry.read(supervisor.scope, 'service')!.restartCount == 1,
      'restart budget not recorded',
    );
    final stop = await provider.stop(
      owned,
      grace: const Duration(milliseconds: 200),
    );
    require(stop.stopped, 'stop unverified: ${stop.message}');
    await waitDead(owned.pid!);
    require(
      await leases.read('service') == null,
      'lease retained after verified stop',
    );
    facts.add(
      ComponentStopped(
        componentId: 'service',
        cause: TerminalCause.signaled,
        message: 'owned provider stop; death and lease removal verified',
      ),
    );
    stages.add({'stage': 'stop', 'deathVerified': true, 'leaseRemoved': true});
    final exhausted = await pass('budget-exhausted');
    require(
      exhausted.plan.actions.isEmpty &&
          exhausted.plan.findings.any((f) => f.code == 'giveUp'),
      'restart budget exceeded',
    );
    passed = true;
  } on Object catch (error) {
    failure = '$error';
    exitCode = 1;
  } finally {
    if (owned != null) {
      final stop = await provider.stop(
        owned,
        grace: const Duration(milliseconds: 200),
      );
      cleanupVerified =
          stop.stopped &&
          !await const HostProcessLiveness().isAlive(owned.pid!);
    } else {
      cleanupVerified = await leases.read('service') == null;
    }
    await facts.close();
    if (!cleanupVerified) exitCode = 1;
    final result = {
      'passed': passed && cleanupVerified,
      'cleanupVerified': cleanupVerified,
      'failure': failure,
      'stages': stages,
      'runnerPid': pid,
      'dartVersion': Platform.version,
      'scope': recover
          ? 'fresh runner after supervisor-host SIGKILL; single-process service'
          : 'single-process service; supervisor runner itself remains alive',
    };
    File(
      '${output.path}/result.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    stdout.writeln(jsonEncode(result));
  }
}
