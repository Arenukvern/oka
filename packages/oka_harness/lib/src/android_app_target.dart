import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;

/// Brings an Android app up through oka's owning dev session.
///
/// `oka dev` is the single owning attach session (build → install → launch
/// → VM-service forward → attach, oka ADR-0011): it compiles, owns the
/// daemon protocol, and publishes the forwarded host-reachable VM endpoint
/// in `<project>/.flutter_mcp/runner-session.json` (mcp_flutter ADR-0014
/// spec v2; absence of the file is the liveness signal). This target spawns
/// it, waits for the file, and returns a [LaunchedApp] around the `oka dev`
/// process — no second attach (which would kill the owning session), no
/// logcat-scraped VM URI guessing.
///
/// App logs under automation surface through adb logcat streamed into the
/// same [LaunchedApp.stdout] tap (prefixed `[logcat] `), so log-based
/// assertions work the same as on desktop targets.
final class AndroidAppTarget implements AppTarget {
  AndroidAppTarget({
    required this.projectDir,
    this.deviceId,
    this.dartDefines = const <String, String>{},
    this.environment = const <String, String>{},
    this.name = 'android-app',
    this.okaBin = 'oka',
    this.logcat = true,
    this.sessionTimeout = const Duration(minutes: 5),
  });

  /// Flutter project directory (oka runs against it and the runner-session
  /// file is read from `<projectDir>/.flutter_mcp/`).
  final String projectDir;

  /// Device serial. Required on multi-device hosts (phone + emulator);
  /// threaded to `oka dev --device`.
  final String? deviceId;

  /// Passed to `oka dev` as `--dart-define` pairs (app config per oka
  /// ADR-0014's three-tier secrets model — defines carry app config, never
  /// host secrets).
  final Map<String, String> dartDefines;
  final Map<String, String> environment;
  final String name;

  /// Override in tests (a fake `oka` script); defaults to `oka` on PATH.
  final String okaBin;
  final bool logcat;
  final Duration sessionTimeout;

  @override
  Future<LaunchedApp> launch({final bool build = true}) async {
    if (!build) {
      throw ArgumentError(
        'AndroidAppTarget always builds through `oka dev`; to observe an '
        'already-running session use readRunnerSessionFile(projectDir) + '
        'VmClient.connect() instead of launching a second owner.',
      );
    }
    // A stale file would look like a live session; the runner deletes it on
    // exit, so anything left is debris (crash, SIGKILL).
    await clearRunnerSessionFile(projectDir);

    final args = <String>[
      'dev',
      if (deviceId != null) ...['--device', deviceId!],
      for (final entry in dartDefines.entries)
        ...['--dart-define', '${entry.key}=${entry.value}'],
    ];
    final process = await Process.start(
      okaBin,
      args,
      workingDirectory: projectDir,
      environment: environment,
    );
    final tap = LogTap()..add('[$name] $okaBin ${args.join(' ')}');
    _pump(process.stdout, tap);
    _pump(process.stderr, tap);

    Process? logcatProcess;
    try {
      final session = await _waitForSession(process, tap);
      if (logcat) {
        logcatProcess = await _startLogcat(session.deviceId, tap);
      }
      return LaunchedApp(
        name: name,
        process: process,
        stdout: tap,
        vmUri: Uri.parse(session.vmServiceUri),
        onStop: () async {
          logcatProcess?.kill();
        },
      );
    } on Object {
      // Never leave an owning session behind on a failed bring-up.
      process.kill();
      rethrow;
    }
  }

  Future<DevSessionDiscovery> _waitForSession(
    final Process process,
    final LogTap tap,
  ) async {
    final deadline = DateTime.now().add(sessionTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final session = readRunnerSessionFile(projectDir);
      if (session != null) return session;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException(
      'oka dev did not publish .flutter_mcp/runner-session.json within '
      '$sessionTimeout; session tail:\n${tap.tail(15).join('\n')}',
    );
  }

  Future<Process?> _startLogcat(final String deviceId, final LogTap tap) async {
    try {
      final process = await Process.start(
        'adb',
        ['-s', deviceId, 'logcat', '-T', '1'],
      );
      _pump(process.stdout, tap, prefix: '[logcat] ');
      _pump(process.stderr, tap, prefix: '[logcat] ');
      return process;
    } on Object {
      // adb unavailable: log assertions fall back to `oka dev` stdout only.
      return null;
    }
  }

  void _pump(
    final Stream<List<int>> stream,
    final LogTap tap, {
    final String prefix = '',
  }) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          prefix.isEmpty ? tap.add : (final line) => tap.add('$prefix$line'),
          onDone: tap.close,
        );
  }
}

/// Convenience: attach a [WidgetDriver] to the live session's VM service.
///
/// Refuses to launch anything — the runner owns the session; this only
/// reads its published endpoint.
Future<WidgetDriver> driverForLiveSession(final String projectDir) async {
  final session = readRunnerSessionFile(projectDir);
  if (session == null) {
    throw StateError(
      'no live runner session at $projectDir '
      '(missing ${p.join(projectDir, '.flutter_mcp', 'runner-session.json')})',
    );
  }
  return WidgetDriver(await VmClient.connect(Uri.parse(session.vmServiceUri)));
}
