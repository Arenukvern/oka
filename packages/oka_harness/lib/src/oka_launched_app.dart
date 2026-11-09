import 'dart:async';
import 'dart:io';

import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';
import 'package:oka_android/oka_android.dart';

/// A running **oka-owned** `oka dev android` session for harness scenarios.
///
/// Prefer [stopSession] over blindly calling [LaunchedApp.stop] on a generic
/// [LaunchedApp] wrapper — SIGTERM does not run the CLI's discovery `finally`.
final class OkaLaunchedApp {
  OkaLaunchedApp({
    required this.name,
    required this.process,
    required this.stdout,
    required this.vmUri,
    required this.projectDir,
    required this.controlPort,
    required this.sessionOwnerPid,
    required this.spawnBinding,
    this.stdinJsonQuitEnabled = false,
    this.onStopExtra,
  });

  final String name;
  final Process process;
  final LogTap stdout;
  final Uri vmUri;
  final String projectDir;
  final int controlPort;

  /// `runner-session.json` `pid` (session owner — may differ from [pid]).
  final int sessionOwnerPid;

  /// Ancestry link between [sessionOwnerPid] and the spawn handle [pid].
  final RunnerSessionSpawnBindingReport spawnBinding;

  /// When true, [stopSession] may write `quit` on stdin (`--json` surface).
  final bool stdinJsonQuitEnabled;
  final Future<void> Function()? onStopExtra;

  VmClient? _vm;

  Future<VmClient> vm() async => _vm ??= await VmClient.connect(vmUri);

  int get pid => process.pid;

  /// Cooperative stop with a [DevSessionStopReport] (truthful limits included).
  /// Logcat and other sidecar teardown without stopping the owning session.
  Future<void> releaseExtras() async {
    try {
      await onStopExtra?.call();
    } on Object {
      // Best-effort after [LaunchedApp.stop] SIGTERM.
    }
  }

  Future<DevSessionStopReport> stopSession({
    Duration quitTimeout = const Duration(seconds: 45),
  }) async {
    final report = await stopOkaDevAndroidSession(
      owningProcess: process,
      projectPath: projectDir,
      controlPort: controlPort,
      stdinJsonQuitEnabled: stdinJsonQuitEnabled,
      quitTimeout: quitTimeout,
    );
    try {
      await onStopExtra?.call();
    } on Object {
      // Logcat tap is best-effort; session receipt is authoritative.
    }
    await stdout.close();
    return report;
  }

  /// Exit code shorthand; use [stopSession] when you need the receipt.
  Future<int> stop() async {
    final report = await stopSession();
    return report.processExitCode ?? (report.ok ? 0 : 1);
  }
}
