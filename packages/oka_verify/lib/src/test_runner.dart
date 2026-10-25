/// The suite runner of the oka verify lane (ADR-0048): the selected suites
/// are spawned through `dart test --precompiled`, so no Common Front End
/// pass happens in the steady state.
///
/// The run is bounded: a deadline stops the runner's process tree through
/// oka's process substrate, and the echoed output is capped. Output beyond
/// the cap is dropped and reported, never silently swallowed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'budget.dart';
import 'import_graph.dart';
import 'runner_kernel.dart';

/// The outcome of running the selected suites.
final class TestRunOutcome {
  const TestRunOutcome({
    required this.exitCode,
    required this.duration,
    this.outputTruncated = false,
    this.timedOut = false,
  });

  /// The exit code of the runner (mirrors `dart test`).
  final int exitCode;

  /// The wall clock of the run.
  final Duration duration;

  /// True when the runner's output hit the echo budget.
  final bool outputTruncated;

  /// True when the runner hit the deadline and was stopped.
  final bool timedOut;

  /// True when the run passed.
  bool get ok => exitCode == 0 && !timedOut;
}

/// Runs the selected suites. An interface so the orchestration can be
/// tested without a compiler or a test runner.
// ignore: one_member_abstracts
abstract interface class SuiteTestRunner {
  /// Runs [suites] (absolute paths) from [workingDirectory], using the
  /// precompiled kernels in [precompiledDir].
  Future<TestRunOutcome> runSuites(
    List<String> suites, {
    required String workingDirectory,
    required String precompiledDir,
  });
}

/// The default runner: `dart test --precompiled=<dir> <suites>`.
final class DartTestRunner implements SuiteTestRunner {
  const DartTestRunner({required this.budget});

  /// The budget that bounds the run.
  final VerifyBudget budget;

  @override
  Future<TestRunOutcome> runSuites(
    List<String> suites, {
    required String workingDirectory,
    required String precompiledDir,
  }) async {
    final watch = Stopwatch()..start();
    final relative = [
      for (final suite in suites) p.relative(suite, from: workingDirectory),
    ];
    final root = testWorkspaceRoot(workingDirectory);
    final graph = await WorkspaceGraph.load(root);
    final requiresAssets = suites.any(graph.reachesNativeAssets);
    final runner = requiresAssets ? null : await testRunnerKernel(root, budget);
    final process = await Process.start(Platform.resolvedExecutable, [
      runner ?? 'test',
      '--precompiled=$precompiledDir',
      ...relative,
    ], workingDirectory: workingDirectory);
    var echoed = 0;
    var truncated = false;
    void echo(String chunk, StringSink sink) {
      if (truncated) return;
      final room = budget.maxEchoBytes - echoed;
      if (room <= 0) {
        truncated = true;
        return;
      }
      if (chunk.length > room) {
        sink.write(chunk.substring(0, room));
        echoed += room;
        truncated = true;
        return;
      }
      sink.write(chunk);
      echoed += chunk.length;
    }

    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => echo('$line\n', stdout));
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => echo('$line\n', stderr));

    var timedOut = false;
    final guard = Timer(budget.runTimeout, () async {
      timedOut = true;
      stderr.writeln(
        '[oka-verify] runner exceeded '
        '${budget.runTimeout.inMinutes}m — stopping the process tree',
      );
      await stopRunnerTree(process);
    });
    final exitCode = await process.exitCode;
    guard.cancel();
    await outDone;
    await errDone;
    watch.stop();
    return TestRunOutcome(
      exitCode: exitCode,
      duration: watch.elapsed,
      outputTruncated: truncated,
      timedOut: timedOut,
    );
  }
}

/// Stops the runner's process tree: enumerate, graceful, force — the same
/// teardown oka uses everywhere else, with the root identity captured at
/// spawn so a recycled pid is never signalled.
Future<void> stopRunnerTree(Process process) async {
  const liveness = HostProcessLiveness();
  String? token;
  try {
    token = await liveness.identityToken(process.pid);
  } on Object {
    token = null;
  }
  await stopProcessTree(
    probe: const HostProcessTreeProbe(),
    liveness: liveness,
    rootPid: process.pid,
    rootIdentityToken: token,
  );
}
