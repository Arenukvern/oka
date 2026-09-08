import 'dart:io';

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

/// Default runner: dart:io [Process.run] with an optional timeout.
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
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
    ).timeout(timeout ?? const Duration(minutes: 30));
    return ProcOutcome(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}
