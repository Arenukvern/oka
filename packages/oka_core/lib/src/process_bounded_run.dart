/// Bounded process runs that kill on deadline instead of abandoning the
/// child (ADR-0026 decision 8, survey failure class F1).
///
/// `Process.run(...).timeout(...)` — Dart's default answer to "run with a
/// deadline" — leaves the child alive when the deadline fires. The agent
/// harness shipped this vector in library code; oka's own
/// `SystemProcessRunner` had the same shape. [runBoundedProcess] never
/// abandons: the deadline fires a tree stop (enumerate → graceful → force,
/// `stopProcessTree`), and the run's `exitCode` is awaited to the end.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'process_liveness.dart';
import 'process_tree.dart';

/// Why a bounded run ended — the meaning of the death, not just the fact.
enum BoundedRunCause {
  /// Exited with [BoundedRunResult.exitCode] before the deadline.
  exited,

  /// Killed by a signal it did not handle (POSIX: negative exit code).
  signaled,

  /// The deadline fired; the tree stop stopped it. [BoundedRunResult.survivors]
  /// lists anything that outlived the ladder.
  killedOnDeadline,

  /// The executable could not be started at all.
  spawnFailed,
}

/// Outcome of a bounded run with bounded output capture.
final class BoundedRunResult {
  const BoundedRunResult({
    required this.cause,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.truncatedOutput,
    required this.duration,
    this.rootPid,
    this.signalNumber,
    this.survivors = const <int>[],
    this.errorMessage,
  });

  final BoundedRunCause cause;
  final int exitCode;

  /// Captured output, bounded by `maxCapturedBytes` per stream.
  final String stdout;
  final String stderr;

  /// True when either stream hit the capture bound and was truncated.
  final bool truncatedOutput;

  final Duration duration;

  /// The spawned child's pid (null only for [BoundedRunCause.spawnFailed]),
  /// so callers can verify death themselves.
  final int? rootPid;

  /// Signal number when [cause] is [BoundedRunCause.signaled].
  final int? signalNumber;

  /// Pids still alive after the deadline's tree stop, if any.
  final List<int> survivors;

  /// Spawn-failure detail when [cause] is [BoundedRunCause.spawnFailed].
  final String? errorMessage;

  bool get ok => cause == BoundedRunCause.exited && exitCode == 0;
}

/// Runs [executable] with [arguments] under a hard [timeout] deadline.
///
/// On deadline the child's whole discovered subtree is stopped via
/// [stopProcessTree] (enumerated before the first signal; the root is
/// identity-gated against the token captured at spawn), and the child's
/// exit is awaited — the call never returns while the child lives, and
/// never leaves the run abandoned. Stdout/stderr are captured up to
/// [maxCapturedBytes] per stream; anything beyond is dropped and flagged.
Future<BoundedRunResult> runBoundedProcess(
  final String executable,
  final List<String> arguments, {
  required final Duration timeout,
  final String? workingDirectory,
  final Map<String, String>? environment,
  final bool runInShell = false,
  final Duration grace = const Duration(seconds: 3),
  final Duration settle = const Duration(milliseconds: 250),
  final int maxCapturedBytes = 256 * 1024,
  final ProcessTreeProbe processTreeProbe = const HostProcessTreeProbe(),
  final ProcessLiveness liveness = const HostProcessLiveness(),
}) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
    );
  } on Object catch (error) {
    return BoundedRunResult(
      cause: BoundedRunCause.spawnFailed,
      exitCode: -1,
      stdout: '',
      stderr: '',
      truncatedOutput: false,
      duration: Duration.zero,
      errorMessage: '$error',
    );
  }
  final watch = Stopwatch()..start();
  final stdoutBuffer = _BoundedBuffer(maxCapturedBytes);
  final stderrBuffer = _BoundedBuffer(maxCapturedBytes);
  final stdoutSub = process.stdout.listen(stdoutBuffer.add);
  final stderrSub = process.stderr.listen(stderrBuffer.add);

  // Identity captured at spawn so the deadline kill is identity-gated.
  String? identityToken;
  try {
    identityToken = await liveness.identityToken(process.pid);
  } on Object {
    identityToken = null;
  }

  final exited = Completer<int>();
  unawaited(
    process.exitCode.then(
      exited.complete,
      onError: (Object error) =>
          exited.completeError(error, StackTrace.current),
    ),
  );

  var deadlineFired = false;
  var stopResult = const TreeStopResult(
    stopped: true,
    survivors: <int>[],
  );
  final deadline = Timer(timeout, () async {
    if (exited.isCompleted) return;
    deadlineFired = true;
    stopResult = await stopProcessTree(
      probe: processTreeProbe,
      liveness: liveness,
      rootPid: process.pid,
      rootIdentityToken: identityToken,
      grace: grace,
      settle: settle,
    );
  });

  final int code;
  try {
    code = await exited.future;
  } finally {
    deadline.cancel();
  }
  watch.stop();
  unawaited(stdoutSub.cancel());
  unawaited(stderrSub.cancel());

  final BoundedRunCause cause;
  if (deadlineFired) {
    cause = BoundedRunCause.killedOnDeadline;
  } else if (code < 0) {
    cause = BoundedRunCause.signaled;
  } else {
    cause = BoundedRunCause.exited;
  }
  return BoundedRunResult(
    cause: cause,
    exitCode: code,
    stdout: stdoutBuffer.text,
    stderr: stderrBuffer.text,
    truncatedOutput: stdoutBuffer.truncated || stderrBuffer.truncated,
    duration: watch.elapsed,
    rootPid: process.pid,
    signalNumber: code < 0 ? -code : null,
    survivors: stopResult.survivors,
  );
}

/// Append-only capture bounded by [capacity] bytes; once full, further
/// bytes are dropped and [truncated] reports it.
final class _BoundedBuffer {
  _BoundedBuffer(this.capacity);

  final int capacity;
  final _bytes = BytesBuilder(copy: false);
  var _size = 0;
  bool truncated = false;

  void add(final List<int> chunk) {
    if (_size >= capacity) {
      truncated = true;
      return;
    }
    final room = capacity - _size;
    if (chunk.length > room) {
      _bytes.add(chunk.sublist(0, room));
      _size += room;
      truncated = true;
      return;
    }
    _bytes.add(chunk);
    _size += chunk.length;
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}
