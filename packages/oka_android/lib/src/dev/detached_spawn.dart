/// Spawning a long-lived child that must **outlive** the process that
/// started it (ADR-0018 §3a).
///
/// Kept in its own, dependency-free library on purpose: the helper is the
/// seam every long-lived spawn uses, and its cost profile matters — a
/// caller that only needs to detach a child should not pull a package
/// graph in to do it.
library;

import 'dart:io';

/// Spawns [executable] as a **detached** child process.
///
/// Detached means three things, and only three:
///
/// 1. the child has **no stdio connection** to the parent — no
///    stdin/stdout/stderr pipes and no exit-code channel (the Dart SDK:
///    "There is no connection to its `stdin`, `stdout` or `stderr`, nor
///    will the process' exit code become available when it terminates").
///    A child's output therefore never reaches the parent's output;
/// 2. the child keeps running when the parent exits;
/// 3. the only handle is the **pid**.
///
/// The mode is load-bearing because of the Dart VM's rule for
/// `ProcessStartMode.normal`: *"The parent process will not exit so long as
/// the child is running"*. A long-lived child spawned in normal mode pins
/// the parent's lifetime — `oka run emulator` could not return while the
/// emulator was up, the opposite of the `stopOnExit=false` contract
/// ("the emulator outlives the CLI").
///
/// The pid is enough for teardown: the process lease records the pid plus
/// the start-time identity token, and every stop re-verifies that token
/// before signaling (ADR-0018 §1).
Future<Process> spawnDetachedProcess(
  String executable,
  List<String> arguments,
) => Process.start(executable, arguments, mode: ProcessStartMode.detached);
