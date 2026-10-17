import 'dart:async';
import 'dart:io';

import 'process_bounded_run.dart';
import 'process_liveness.dart';
import 'process_tree.dart';

/// Result of an external process invocation.
class ProcOutcome {
  const ProcOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Exit code of the child process.
  final int exitCode;

  /// Standard output, decoded.
  final String stdout;

  /// Standard error, decoded.
  final String stderr;

  /// `true` when the process exited cleanly.
  bool get ok => exitCode == 0;
}

/// Injectable process runner (ADR-0007): every tool invocation flows through
/// this interface so steps are testable without real SDKs and timeouts are
/// enforced uniformly.
// ignore: one_member_abstracts
abstract class ProcessRunner {
  /// Runs [executable] with [arguments]; returns the outcome. [timeout]
  /// defaults to 30 minutes in the default implementation.
  Future<ProcOutcome> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  });
}

/// Default runner: dart:io invocation with a deadline stop request.
///
/// The deadline **kills the process tree** (graceful→force, verified death)
/// instead of abandoning the child the way a bare `Future.timeout` does
/// (ADR-0026 decision 8); the [TimeoutException] contract is preserved so
/// callers keep their existing failure handling. Failed discovery/teardown is
/// reported with root recovery identity; it never establishes zero survivors.
class SystemProcessRunner implements ProcessRunner {
  /// The same platform seams used by bounded runs; defaults use the host OS.
  const SystemProcessRunner({
    this.processTreeProbe = const HostProcessTreeProbe(),
    this.liveness = const HostProcessLiveness(),
    this.observationBudget = const Duration(seconds: 2),
  });

  final ProcessTreeProbe processTreeProbe;
  final ProcessLiveness liveness;
  /// Aggregate direct read budget per stop; excludes mutation/grace time.
  final Duration observationBudget;

  @override
  Future<ProcOutcome> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(minutes: 30);
    final result = await runBoundedProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
      timeout: effectiveTimeout,
      processTreeProbe: processTreeProbe,
      liveness: liveness,
      observationBudget: observationBudget,
    );
    switch (result.cause) {
      case BoundedRunCause.spawnFailed:
        throw ProcessException(
          executable,
          arguments,
          result.errorMessage ?? 'Failed to start.',
        );
      case BoundedRunCause.killedOnDeadline:
        final cleanup = result.teardownVerified == true
            ? 'verified tree teardown'
            : 'UNVERIFIED teardown; root=${result.rootPid}, '
                  'identity=${result.rootIdentityToken ?? "unknown"}, '
                  'rootExitObserved=${result.rootExitObserved}, '
                  'known survivors=${result.survivors}; '
                  '${result.errorMessage ?? "discovery unknown"}';
        throw TimeoutException(
          'Process stop requested after the ${effectiveTimeout.inMilliseconds}ms '
          'deadline ($cleanup).',
          effectiveTimeout,
        );
      case BoundedRunCause.signaled:
      case BoundedRunCause.exited:
        return ProcOutcome(
          exitCode: result.exitCode,
          stdout: result.stdout,
          stderr: result.stderr,
        );
    }
  }
}
