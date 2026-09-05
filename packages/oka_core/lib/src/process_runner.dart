import 'dart:io';

/// Result of an external process invocation.
class ProcOutcome {
  final int exitCode;
  final String stdout;
  final String stderr;

  const ProcOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  bool get ok => exitCode == 0;
}

/// Injectable process runner (ADR-0007): every tool invocation flows through
/// this interface so steps are testable without real SDKs and timeouts are
/// enforced uniformly.
abstract class ProcessRunner {
  Future<ProcOutcome> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  });
}

/// Default runner: dart:io [Process.run] with an optional timeout.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcOutcome> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
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
