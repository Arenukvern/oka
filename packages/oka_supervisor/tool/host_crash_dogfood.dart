// Local callback parameters stay compatible with Dart 3.13.
// ignore_for_file: prefer_final_parameters
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:oka_core/oka_core.dart';
import 'package:resource_composition/resource_composition.dart';

/// Verifies recovery in a fresh process after killing an owned runner.
Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('NEW_OUTPUT required');
  final output = Directory(args.single).absolute;
  if (output.existsSync()) throw StateError('refusing existing evidence');
  for (final mode in ['birth', 'recover']) {
    if (File('${output.path}-$mode.log').existsSync()) {
      throw StateError('refusing existing worker log');
    }
  }
  final worker = File.fromUri(
    Platform.script.resolve('service_lifecycle_dogfood.dart'),
  );
  const liveness = HostProcessLiveness();
  final children =
      <
        ({
          Process process,
          String? identity,
          IOSink log,
          StreamSubscription<List<int>> out,
          StreamSubscription<List<int>> err,
        })
      >[];
  var passed = false;
  String? failure;
  bool? survived;
  Future<Process> start(String mode) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      worker.path,
      mode,
      output.path,
    ]);
    final token = await liveness.identityToken(process.pid);
    // The birth worker creates the evidence root; logs use a temporary sibling
    // until birth creates the new root.
    // The controller closes this sink and both subscriptions in its finally.
    // ignore: close_sinks
    final log = File('${output.path}-${mode.substring(2)}.log').openWrite();
    // ignore: cancel_subscriptions
    final out = process.stdout.listen(log.add);
    // ignore: cancel_subscriptions
    final err = process.stderr.listen(log.add);
    children.add((
      process: process,
      identity: token,
      log: log,
      out: out,
      err: err,
    ));
    return process;
  }

  Future<void> killRunner(Process process) async {
    final child = children.singleWhere((c) => c.process == process);
    final verdict = await verifyKillIdentity(
      liveness,
      process.pid,
      child.identity,
    );
    if (verdict != KillIdentity.verified) {
      throw StateError('runner kill identity $verdict');
    }
    if (!process.kill(ProcessSignal.sigkill)) {
      throw StateError('runner signal refused');
    }
    await process.exitCode.timeout(const Duration(seconds: 5));
  }

  try {
    final original = await start('--birth');
    final deadline = Stopwatch()..start();
    final marker = File('${output.path}/birth.json');
    while (!marker.existsSync()) {
      if (!await liveness.isAlive(original.pid)) {
        throw StateError('birth runner exited before receipt');
      }
      if (deadline.elapsed > const Duration(seconds: 60)) {
        throw TimeoutException('birth receipt');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final birth = jsonDecode(marker.readAsStringSync()) as Map;
    if (birth['runnerPid'] != original.pid) {
      throw StateError('wrong birth runner');
    }
    await killRunner(original);
    final servicePid = birth['servicePid'] as int;
    survived =
        await liveness.isAlive(servicePid) &&
        await verifyKillIdentity(
              liveness,
              servicePid,
              birth['serviceIdentityToken'] as String?,
            ) ==
            KillIdentity.verified;
    if (!survived) throw StateError('service did not survive runner crash');
    final recovery = await start('--recover');
    final code = await recovery.exitCode.timeout(const Duration(seconds: 30));
    final result =
        jsonDecode(File('${output.path}/result.json').readAsStringSync())
            as Map;
    if (code != 0 ||
        result['passed'] != true ||
        result['runnerPid'] != recovery.pid ||
        recovery.pid == original.pid) {
      throw StateError('fresh runner recovery failed: $result');
    }
    passed = true;
  } on Object catch (error) {
    failure = '$error';
    exitCode = 1;
  } finally {
    final cleanupErrors = <String>[];
    for (final child in children) {
      try {
        if (await liveness.isAlive(child.process.pid)) {
          await killRunner(child.process);
        }
      } on Object catch (error) {
        cleanupErrors.add('runner ${child.process.pid}: $error');
      }
      try {
        await child.out.cancel();
        await child.err.cancel();
        await child.log.close();
      } on Object catch (error) {
        cleanupErrors.add('runner log ${child.process.pid}: $error');
      }
    }
    // Recover/stop only this new root's owned lease, even after a failed trial.
    final leases = ProcessLeaseRegistry.forProject(output.path);
    final lease = await leases.read('service');
    var cleanup = lease == null;
    try {
      if (lease != null) {
        final provider = LeasedProcessProvider(
          leaseId: 'service',
          command: const ProcessCommand('unused'),
          registry: leases,
        );
        final stopped = await provider.stop(
          ResourceRef(
            componentId: 'service',
            handle: 'service',
            pid: lease.pid,
            identityToken: lease.identity[processLeasePidTokenKey],
          ),
          grace: const Duration(milliseconds: 200),
        );
        cleanup = stopped.stopped && !await liveness.isAlive(lease.pid);
      }
    } on Object catch (error) {
      cleanupErrors.add('service: $error');
      cleanup = false;
    }
    cleanup = cleanup && cleanupErrors.isEmpty;
    if (!cleanup) exitCode = 1;
    output.createSync(recursive: true);
    final result = {
      'passed': passed && cleanup,
      'failure': failure,
      'serviceSurvivedRunnerKill': survived,
      'cleanupVerified': cleanup,
      'cleanupErrors': cleanupErrors,
      'scope':
          'one owned supervisor runner and one single-process Dart service',
    };
    File(
      '${output.path}/host-crash-result.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    stdout.writeln(jsonEncode(result));
  }
}
