import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Frozen subtree captured while the root was still enumerable (before
/// reparenting). Kill authority is limited to these pids + stored identities.
final class SessionOwnedTree {
  SessionOwnedTree({
    required this.rootPid,
    required this.identities,
    required this.descendantPids,
  });

  final int rootPid;
  final Map<int, String?> identities;
  final List<int> descendantPids;

  List<int> get allTrackedPids => [rootPid, ...descendantPids];
}

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
  OwnedDevSession._({
    required this.process,
    this.treeProbe = const HostProcessTreeProbe(),
    this.liveness = const HostProcessLiveness(),
  });

  final Process process;
  final ProcessTreeProbe treeProbe;
  final ProcessLiveness liveness;
  String? identityToken;
  SessionOwnedTree? _ownedTree;
  final StringBuffer _buffer = StringBuffer();
  late StreamSubscription<String> _stdoutSub;
  late StreamSubscription<String> _stderrSub;
  Completer<OwnedDevSessionTeardown>? _teardownOnce;

  String get transcript => _buffer.toString();
  SessionOwnedTree? get ownedTree => _ownedTree;

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

  /// Enumerates and freezes pid → identity under the session root. Call
  /// after spawn and again once the session is ready (before the root may
  /// exit).
  Future<void> snapshotOwnedTree() async {
    final pid = process.pid;
    if (pid <= 0) return;
    final tree = await treeProbe.enumerate(pid);
    if (tree == null) return;
    final descendants = tree.descendants();
    final identities = <int, String?>{};
    identities[pid] = identityToken ?? await liveness.identityToken(pid);
    for (final child in descendants) {
      try {
        identities[child] = await liveness.identityToken(child);
      } on Object {
        identities[child] = null;
      }
    }
    _ownedTree = SessionOwnedTree(
      rootPid: pid,
      identities: identities,
      descendantPids: descendants,
    );
  }

  /// Spawns `oka run dev` (optionally under `xvfb-run -a`) and begins capture.
  static Future<OwnedDevSession> start({
    required String workspace,
    required List<String> dartInvocation,
    bool useXvfb = false,
    Map<String, String>? environment,
    String? workingDirectory,
    Duration identityBudget = const Duration(seconds: 2),
    DevSessionSpawner spawn = defaultDevSessionSpawn,
    ProcessTreeProbe? treeProbe,
    ProcessLiveness? liveness,
  }) async {
    final dart = _dartVmExecutable();
    final cwd = workingDirectory ?? workspace;
    final Process proc;
    if (useXvfb) {
      proc = await spawn(
        'xvfb-run',
        ['-a', dart, ...dartInvocation],
        workingDirectory: cwd,
        environment: environment,
      );
    } else {
      proc = await spawn(
        dart,
        dartInvocation,
        workingDirectory: cwd,
        environment: environment,
      );
    }

    final session = OwnedDevSession._(
      process: proc,
      treeProbe: treeProbe ?? const HostProcessTreeProbe(),
      liveness: liveness ?? const HostProcessLiveness(),
    );
    session._stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => session._append('$line\n'));
    session._stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => session._append('$line\n'));

    try {
      session.identityToken = await session.liveness
          .identityToken(proc.pid)
          .timeout(identityBudget);
    } on Object {
      session.identityToken = null;
    }
    await session.snapshotOwnedTree();
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

  Future<bool> _killIfOwnedIdentity(int pid, String? expected) async {
    if (expected == null || pid <= 0) return false;
    if (!await liveness.isAlive(pid)) return true;
    final String? current;
    try {
      current = await liveness.identityToken(pid);
    } on Object {
      return false;
    }
    if (current == null || current != expected) return false;
    return liveness.kill(pid, grace: const Duration(milliseconds: 400));
  }

  Future<List<int>> _stopFromOwnedSnapshot() async {
    final tree = _ownedTree;
    if (tree == null) return const [];

    final rootAlive = await liveness.isAlive(tree.rootPid);
    if (rootAlive && tree.rootPid > 0) {
      final stop = await stopProcessTree(
        probe: treeProbe,
        liveness: liveness,
        rootPid: tree.rootPid,
        rootIdentityToken: tree.identities[tree.rootPid],
      );
      if (stop.survivors.isEmpty && stop.stopped) return const [];
      if (stop.survivors.isNotEmpty) return stop.survivors;
    }

    final survivors = <int>[];
    final ordered = [...tree.descendantPids.reversed, tree.rootPid];
    for (final pid in ordered) {
      final ok = await _killIfOwnedIdentity(pid, tree.identities[pid]);
      if (!ok && await liveness.isAlive(pid)) {
        survivors.add(pid);
      }
    }
    return survivors;
  }

  /// `q` + bounded wait, then identity-gated tree stop on survivors.
  Future<OwnedDevSessionTeardown> teardown({
    Duration quitGrace = const Duration(seconds: 45),
    Duration stopGrace = const Duration(seconds: 5),
    Duration settle = const Duration(milliseconds: 250),
  }) async {
    if (_teardownOnce != null) return _teardownOnce!.future;
    final once = Completer<OwnedDevSessionTeardown>();
    _teardownOnce = once;
  try {
    final td = await _teardownImpl(
      quitGrace: quitGrace,
      stopGrace: stopGrace,
      settle: settle,
    );
    once.complete(td);
    return td;
  } on Object catch (e, st) {
    once.completeError(e, st);
    rethrow;
  }
  }

  Future<OwnedDevSessionTeardown> _teardownImpl({
    required Duration quitGrace,
    required Duration stopGrace,
    required Duration settle,
  }) async {
    final notes = <String>[];
    final rootAliveBefore = await liveness.isAlive(process.pid);
    if (rootAliveBefore) {
      await snapshotOwnedTree();
    }

    try {
      if (rootAliveBefore) {
        process.stdin.writeln('q');
        await process.stdin.close();
      }
    } on Object catch (e) {
      notes.add('stdin close: $e');
    }

    int? exitCode;
    if (rootAliveBefore) {
      try {
        exitCode = await process.exitCode.timeout(quitGrace);
      } on TimeoutException {
        notes.add('root did not exit within ${quitGrace.inSeconds}s after q');
      }
    } else {
      notes.add('root already exited before teardown');
      try {
        exitCode = await process.exitCode;
      } on Object {
        exitCode = null;
      }
    }

    await _stdoutSub.cancel();
    await _stderrSub.cancel();

    final survivors = await _stopFromOwnedSnapshot();
    if (survivors.isEmpty &&
        _ownedTree != null &&
        (await liveness.isAlive(_ownedTree!.rootPid) ||
            (await Future.wait(
              _ownedTree!.descendantPids.map(liveness.isAlive),
            )).any((a) => a))) {
      notes.add('tracked tree still alive after owned stop attempt');
    }

    final stillAlive = <int>[];
    if (_ownedTree != null) {
      for (final pid in _ownedTree!.allTrackedPids) {
        if (await liveness.isAlive(pid)) stillAlive.add(pid);
      }
    } else if (await liveness.isAlive(process.pid)) {
      stillAlive.add(process.pid);
    }

    final mergedSurvivors = {
      ...survivors,
      ...stillAlive,
    }.toList();

    return OwnedDevSessionTeardown(
      clean: mergedSurvivors.isEmpty,
      exitCode: exitCode,
      survivors: mergedSurvivors,
      notes: notes,
    );
  }
}
