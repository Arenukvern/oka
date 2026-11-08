import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Teardown of an owned `oka run dev` child (no pattern-kill of unrelated apps).
final class OwnedDevSessionTeardown {
  const OwnedDevSessionTeardown({
    required this.clean,
    required this.exitCode,
    this.survivors = const [],
    this.notes = const [],
  });

  final bool clean;
  final int? exitCode;
  final List<int> survivors;
  final List<String> notes;
}

typedef DevSessionSpawner = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

/// Dart-owned dev session: one root process, bounded stop, transcript capture.
final class OwnedDevSession {
  OwnedDevSession._({required this.process});

  final Process process;
  String? identityToken;
  final StringBuffer _buffer = StringBuffer();
  late StreamSubscription<String> _stdoutSub;
  late StreamSubscription<String> _stderrSub;

  String get transcript => _buffer.toString();

  void _append(String chunk) => _buffer.write(chunk);

  static String _dartVmExecutable() {
    final exe = Platform.resolvedExecutable;
    final base = p.basename(exe);
    if (base == 'dartaotruntime' || base == 'dartaotruntime.exe') {
      final sibling = p.join(p.dirname(exe), 'dart');
      if (File(sibling).existsSync()) return sibling;
    }
    return exe;
  }

  static Future<Process> defaultDevSessionSpawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) =>
      Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );

  /// Spawns `oka run dev` (optionally under `xvfb-run -a`) and begins capture.
  static Future<OwnedDevSession> start({
    required String workspace,
    required List<String> dartInvocation,
    bool useXvfb = false,
    Map<String, String>? environment,
    Duration identityBudget = const Duration(seconds: 2),
    DevSessionSpawner spawn = defaultDevSessionSpawn,
  }) async {
    final dart = _dartVmExecutable();
    final Process proc;
    if (useXvfb) {
      proc = await spawn(
        'xvfb-run',
        ['-a', dart, ...dartInvocation],
        workingDirectory: workspace,
        environment: environment,
      );
    } else {
      proc = await spawn(
        dart,
        dartInvocation,
        workingDirectory: workspace,
        environment: environment,
      );
    }

    final session = OwnedDevSession._(process: proc);
    session._stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => session._append('$line\n'));
    session._stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => session._append('$line\n'));

    try {
      session.identityToken = await const HostProcessLiveness()
          .identityToken(proc.pid)
          .timeout(identityBudget);
    } on Object {
      session.identityToken = null;
    }
    return session;
  }

  void sendLine(String line) {
    process.stdin.writeln(line);
  }

  Future<bool> waitForPattern(
    Pattern pattern, {
    Duration timeout = const Duration(minutes: 30),
    Duration poll = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_containsPattern(pattern)) return true;
      await Future<void>.delayed(poll);
    }
    return false;
  }

  bool _containsPattern(Pattern pattern) {
    final text = transcript;
    if (pattern is RegExp) return pattern.hasMatch(text);
    if (pattern is String) return text.contains(pattern);
    return pattern.allMatches(text).isNotEmpty;
  }

  /// `q` + bounded wait, then identity-gated tree stop on survivors.
  Future<OwnedDevSessionTeardown> teardown({
    Duration quitGrace = const Duration(seconds: 45),
    Duration stopGrace = const Duration(seconds: 5),
    Duration settle = const Duration(milliseconds: 250),
  }) async {
    final notes = <String>[];
    try {
      process.stdin.writeln('q');
      await process.stdin.close();
    } on Object catch (e) {
      notes.add('stdin close: $e');
    }

    int? exitCode;
    try {
      exitCode = await process.exitCode.timeout(quitGrace);
    } on TimeoutException {
      notes.add('root did not exit within ${quitGrace.inSeconds}s after q');
    }

    await _stdoutSub.cancel();
    await _stderrSub.cancel();

    const liveness = HostProcessLiveness();
    final alive =
        exitCode == null && await liveness.isAlive(process.pid);

    if (!alive) {
      return OwnedDevSessionTeardown(
        clean: exitCode == 0,
        exitCode: exitCode,
        notes: notes,
      );
    }

    final token = identityToken;
    if (token == null) {
      return OwnedDevSessionTeardown(
        clean: false,
        exitCode: exitCode,
        survivors: [process.pid],
        notes: [
          ...notes,
          'startup identity unavailable; refused tree stop',
        ],
      );
    }

    final stop = await stopProcessTree(
      probe: const HostProcessTreeProbe(),
      liveness: const HostProcessLiveness(),
      rootPid: process.pid,
      rootIdentityToken: token,
      grace: stopGrace,
      settle: settle,
    );
    notes.addAll(stop.notes);

    return OwnedDevSessionTeardown(
      clean: stop.stopped && stop.survivors.isEmpty,
      exitCode: exitCode,
      survivors: stop.survivors,
      notes: notes,
    );
  }
}
