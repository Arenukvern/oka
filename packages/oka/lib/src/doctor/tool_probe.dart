import 'package:oka_core/oka_core.dart';

/// Result of a bounded external-tool probe (doctor / gates).
final class ToolProbeResult {
  const ToolProbeResult({
    required this.ran,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.missing = false,
    this.timedOut = false,
    this.spawnFailed = false,
    this.errorMessage,
  });

  final bool ran;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final bool missing;
  final bool timedOut;
  final bool spawnFailed;
  final String? errorMessage;

  bool get ok => ran && exitCode == 0 && !missing && !timedOut && !spawnFailed;
}

typedef ToolProbeRunner = Future<ToolProbeResult> Function(
  String executable,
  List<String> arguments, {
  Duration deadline,
});

Future<ToolProbeResult> defaultToolProbe(
  String executable,
  List<String> arguments, {
  Duration deadline = const Duration(seconds: 15),
}) async {
  final result = await runBoundedProcess(
    executable,
    arguments,
    timeout: deadline,
    maxCapturedBytes: 512 * 1024,
  );
  if (result.cause == BoundedRunCause.spawnFailed) {
    final msg = result.errorMessage ?? '';
    final missing = msg.contains('Failed to start') ||
        msg.contains('No such file') ||
        msg.contains('not found');
    return ToolProbeResult(
      ran: false,
      missing: missing,
      spawnFailed: !missing,
      errorMessage: msg.isEmpty ? 'spawn failed' : msg,
    );
  }
  if (result.cause == BoundedRunCause.killedOnDeadline ||
      result.cause == BoundedRunCause.cancelled) {
    return ToolProbeResult(
      ran: false,
      timedOut: true,
      stdout: result.stdout,
      stderr: result.stderr,
      errorMessage: 'deadline (${deadline.inSeconds}s)',
    );
  }
  return ToolProbeResult(
    ran: true,
    exitCode: result.exitCode,
    stdout: result.stdout,
    stderr: result.stderr,
  );
}
