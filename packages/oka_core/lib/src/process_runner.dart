import 'dart:async';
import 'dart:io';

import 'process_bounded_run.dart';

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
    final String executable,
    final List<String> arguments, {
    final String? workingDirectory,
    final Map<String, String>? environment,
    final Duration? timeout,
  });
}

/// Default runner: dart:io [Process.run] semantics with a hard deadline.
///
/// The deadline **kills the process tree** (graceful→force, verified death)
/// instead of abandoning the child the way a bare `Future.timeout` does
/// (ADR-0026 decision 8); the [TimeoutException] contract is preserved so
/// callers keep their existing failure handling, but nothing survives it.
class SystemProcessRunner implements ProcessRunner {
  /// Const constructor — stateless.
  const SystemProcessRunner();

  @override
  Future<ProcOutcome> run(
    final String executable,
    final List<String> arguments, {
    final String? workingDirectory,
    final Map<String, String>? environment,
    final Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(minutes: 30);
    final result = await runBoundedProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
      timeout: effectiveTimeout,
    );
    switch (result.cause) {
      case BoundedRunCause.spawnFailed:
        throw ProcessException(
          executable,
          arguments,
          result.errorMessage ?? 'Failed to start.',
        );
      case BoundedRunCause.killedOnDeadline:
        final survivors = result.survivors.isEmpty
            ? 'no survivors'
            : 'SURVIVORS: ${result.survivors}';
        throw TimeoutException(
          'Process killed after the ${effectiveTimeout.inMilliseconds}ms '
          'deadline ($survivors).',
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
