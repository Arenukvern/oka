/// Bounded process runs that kill on deadline instead of abandoning the
/// child (ADR-0026 decision 8, survey failure class F1).
///
/// `Process.run(...).timeout(...)` — Dart's default answer to "run with a
/// deadline" — leaves the child alive when the deadline fires. The agent
/// harness shipped this vector in library code; oka's own
/// `SystemProcessRunner` had the same shape. The deadline requests tree stop
/// (enumerate → graceful → force); a failed stop returns an explicit recovery
/// receipt rather than waiting indefinitely for a live root (ADR-0046).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'process_liveness.dart';
import 'process_observation_budget.dart';
import 'process_tree.dart';

/// Why a bounded run ended — the meaning of the death, not just the fact.
enum BoundedRunCause {
  /// Exited with [BoundedRunResult.exitCode] before the deadline.
  exited,

  /// Killed by a signal it did not handle (POSIX: negative exit code).
  signaled,

  /// The deadline fired and requested tree stop. Check
  /// [BoundedRunResult.teardownVerified] independently of the root exit;
  /// [BoundedRunResult.survivors] lists known survivors.
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
    this.rootIdentityToken,
    this.rootExitObserved = true,
    this.signalNumber,
    this.teardownVerified,
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

  /// Identity captured at spawn for a later identity-gated recovery attempt.
  final String? rootIdentityToken;

  /// False when a failed deadline stop returned before root exit was observed.
  /// In that case [exitCode] is -1, not a signal or observed terminal status.
  final bool rootExitObserved;

  /// Signal number when [cause] is [BoundedRunCause.signaled].
  final int? signalNumber;

  /// Deadline teardown result. Null when no deadline stop was requested;
  /// false means discovery/identity/death did not verify a complete stop.
  final bool? teardownVerified;

  /// Pids still alive after the deadline's tree stop, if any.
  final List<int> survivors;

  /// Spawn failure or unverified deadline-teardown detail.
  final String? errorMessage;

  bool get ok => cause == BoundedRunCause.exited && exitCode == 0;
}

/// Runs [executable] with [arguments] and a [timeout] stop-request deadline.
///
/// On deadline the child's whole discovered subtree is stopped via
/// [stopProcessTree] (enumerated before the first signal; the root is
/// identity-gated against the token captured at spawn), and the child's
/// exit is awaited after successful teardown. Failed teardown returns the
/// unresolved root and cleanup receipt; callers must retain these for recovery.
/// Direct platform reads use [observationBudget]; mutating adapters remain
/// awaited, and a timed-out read's underlying resources remain adapter-owned.
/// Output is captured up to
/// [maxCapturedBytes] per stream; anything beyond is dropped and flagged.
Future<BoundedRunResult> runBoundedProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
  bool runInShell = false,
  Duration grace = const Duration(seconds: 3),
  Duration settle = const Duration(milliseconds: 250),
  int maxCapturedBytes = 256 * 1024,
  ProcessTreeProbe processTreeProbe = const HostProcessTreeProbe(),
  ProcessLiveness liveness = const HostProcessLiveness(),
  Duration observationBudget = const Duration(seconds: 2),
}) async {
  ProcessObservationBudget(observationBudget); // Validate before spawning.
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
      rootExitObserved: false,
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
    final remaining = timeout - watch.elapsed;
    final captureBudget = remaining < observationBudget
        ? remaining
        : observationBudget;
    if (captureBudget > Duration.zero) {
      identityToken = await liveness
          .identityToken(process.pid)
          .timeout(captureBudget);
    }
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
  var stopResult = const TreeStopResult(stopped: true, survivors: <int>[]);
  Future<TreeStopResult>? stopping;
  final deadlineStopped = Completer<TreeStopResult>();
  final remaining = timeout - watch.elapsed;
  final deadline = Timer(
    remaining > Duration.zero ? remaining : Duration.zero,
    () {
      if (exited.isCompleted) return;
      deadlineFired = true;
      stopping = identityToken == null
          ? Future.value(
              TreeStopResult(
                stopped: false,
                survivors: [process.pid],
                notes: [
                  'startup identity unavailable; refused signals; survivors unknown',
                ],
              ),
            )
          : stopProcessTree(
              probe: processTreeProbe,
              liveness: liveness,
              rootPid: process.pid,
              rootIdentityToken: identityToken,
              grace: grace,
              settle: settle,
              observationBudget: observationBudget,
            ).catchError(
              (Object error) => TreeStopResult(
                stopped: false,
                survivors: const [],
                notes: ['tree teardown failed; survivors unknown: $error'],
              ),
            );
      unawaited(stopping!.then(deadlineStopped.complete));
    },
  );

  final int code;
  final bool rootExitObserved;
  try {
    // A completed failed stop must become visible even while the root lives.
    // Root exit still waits for tree verification; verified stop still waits
    // for the spawned process's terminal status.
    await Future.any<Object?>([exited.future, deadlineStopped.future]);
    final teardown = stopping;
    if (teardown != null) stopResult = await teardown;
    rootExitObserved = exited.isCompleted || stopResult.stopped;
    code = rootExitObserved ? await exited.future : -1;
  } finally {
    deadline.cancel();
  }
  watch.stop();
  Future<void> closeCapture() async {
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }

  if (rootExitObserved) {
    await closeCapture();
  } else {
    // Closing a live writer's pipe can terminate it. A refused stop must not
    // acquire an accidental signal path: retain bounded draining until exit.
    unawaited(
      exited.future
          .then<void>(
            (_) => closeCapture(),
            onError: (Object _, StackTrace _) => closeCapture(),
          )
          .catchError((Object _) {}),
    );
  }

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
    rootIdentityToken: identityToken,
    rootExitObserved: rootExitObserved,
    signalNumber: rootExitObserved && code < 0 ? -code : null,
    survivors: [
      ...stopResult.survivors,
      if (!rootExitObserved && !stopResult.survivors.contains(process.pid))
        process.pid,
    ],
    teardownVerified: deadlineFired ? stopResult.stopped : null,
    errorMessage: deadlineFired && !stopResult.stopped
        ? stopResult.notes.join('; ')
        : null,
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

  void add(List<int> chunk) {
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
