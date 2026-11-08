import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../package_root.dart';

import 'owned_dev_session_start_controller.dart';
import 'supervisor_control_channel.dart';
import 'supervisor_session_protocol.dart';

/// Frozen view of the last successful probe (debug/tests).
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

/// Cumulative ownership: union of every snapshot; never replaced.
final class _OwnershipLedger {
  int? workloadRootPid;
  final Map<int, String?> identities = {};
  final Set<int> descendantPids = {};
  bool enumerationUnavailable = false;
  int successfulSnapshots = 0;
  final List<String> errors = [];

  void merge({
    required int rootPid,
    required List<int> descendants,
    required Map<int, String?> newIdentities,
  }) {
    successfulSnapshots++;
    workloadRootPid = rootPid;
    identities.addAll(newIdentities);
    descendantPids.addAll(descendants);
  }

  void recordEnumerationFailure([String? detail]) {
    enumerationUnavailable = true;
    if (detail != null) errors.add(detail);
  }

  List<int> get allTrackedPids => {
        if (workloadRootPid != null && workloadRootPid! > 0) workloadRootPid!,
        ...descendantPids,
      }.toList();

  bool get hasProvableOwnership => successfulSnapshots > 0 && identities.isNotEmpty;
}

/// Teardown of an owned `oka run dev` child (no pattern-kill of unrelated apps).
final class OwnedDevSessionTeardown {
  const OwnedDevSessionTeardown({
    required this.clean,
    required this.verified,
    required this.exitCode,
    this.workloadExitCode,
    this.survivors = const [],
    this.notes = const [],
  });

  /// No tracked survivors and ownership boundary was verified.
  final bool clean;

  /// False when enumeration/unknown survivors prevent a success claim.
  final bool verified;

  /// Supervisor wrapper exit status (not the workload's).
  final int? exitCode;
  final int? workloadExitCode;
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
    required this.sessionNonce,
    this.treeProbe = const HostProcessTreeProbe(),
    this.liveness = const HostProcessLiveness(),
    this.useSubreaperSupervisor = false,
    this._controlSink,
  });

  final Process process;
  final String sessionNonce;
  final ProcessTreeProbe treeProbe;
  final ProcessLiveness liveness;
  final bool useSubreaperSupervisor;
  String? identityToken;
  int? _workloadPid;
  SupervisorDrainAck? _drainAck;
  final Map<int, String> _fixtureEscapedByPid = {};
  SessionOwnedTree? _ownedTree;
  final _OwnershipLedger _ledger = _OwnershipLedger();
  final StringBuffer _buffer = StringBuffer();
  late StreamSubscription<String> _stdoutSub;
  late StreamSubscription<String> _stderrSub;
  Completer<OwnedDevSessionTeardown>? _teardownOnce;
  final File? _controlSink;
  int _controlReadOffset = 0;
  Timer? _controlPumpTimer;
  int? _workloadExitFromControl;

  SupervisorDrainAck? get drainAck => _drainAck;
  Map<int, String> get fixtureEscaped => Map.unmodifiable(_fixtureEscapedByPid);

  String get transcript => _buffer.toString();
  SessionOwnedTree? get ownedTree => _ownedTree;
  _OwnershipLedger get ownershipLedger => _ledger;

  int _resolveTreeRoot() => _workloadPid ?? process.pid;

  void _append(String chunk) {
    _buffer.write(chunk);
    for (final line in chunk.split('\n')) {
      final trimmed = line.trim();
      final match = RegExp(r'^oka_dev_workload_pid=(\d+)$').firstMatch(trimmed);
      if (match != null) {
        _workloadPid = int.parse(match.group(1)!);
      }
      final escaped = parseFixtureEscapedReport(trimmed);
      if (escaped != null) {
        _fixtureEscapedByPid[escaped.pid] = escaped.token;
      }
    }
  }

  void _attachLineStreams() {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _append('$line\n'));
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _append('$line\n'));
  }

  static void _assertSupervisorEntrypointAllowed({
    required String kernelRoot,
    required String productionSupervisor,
    required String entrypoint,
  }) {
    final normalized = p.normalize(entrypoint);
    final production = p.normalize(productionSupervisor);
    final fixtures = p.normalize(p.join(kernelRoot, 'test', 'fixtures'));
    if (normalized == production || p.isWithin(fixtures, normalized)) {
      return;
    }
    throw ArgumentError.value(
      entrypoint,
      'supervisorEntrypoint',
      'must be the production linux_subreaper_supervisor.dart or a file '
      'under packages/oka_dart_kernel/test/fixtures/',
    );
  }

  static String _freshSessionNonce() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(0x7fffffff)}';
  }

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

  static Future<Process> _spawnWithOptionalSupervisor({
    required String executable,
    required List<String> arguments,
    required bool useSupervisor,
    required DevSessionSpawner spawn,
    required String sessionNonce,
    required String? controlPath,
    String? supervisorEntrypoint,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (!useSupervisor || !Platform.isLinux) {
      return spawn(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    }
    final kernelRoot = await resolveOkaDartKernelRoot();
    final productionSupervisor = p.join(
      kernelRoot,
      'tool',
      'linux_subreaper_supervisor.dart',
    );
    final supervisor = supervisorEntrypoint ?? productionSupervisor;
    if (supervisorEntrypoint != null) {
      _assertSupervisorEntrypointAllowed(
        kernelRoot: kernelRoot,
        productionSupervisor: productionSupervisor,
        entrypoint: supervisor,
      );
    }
    final env = Map<String, String>.from(environment ?? Platform.environment);
    env.remove(kLegacySessionNonceEnv);
    env[kSupervisorNonceEnv] = sessionNonce;
    if (controlPath != null) {
      env[kSupervisorAckPathEnv] = controlPath;
    }
    final cwd = workingDirectory;
    if (cwd != null && cwd.isNotEmpty) {
      env['OKA_DEV_SESSION_CWD'] = cwd;
    }
    return spawn(
      _dartVmExecutable(),
      [supervisor, '--', executable, ...arguments],
      environment: env,
    );
  }

  /// Returns false when enumeration was unavailable (ledger records failure).
  Future<bool> snapshotOwnedTree() async {
    final pid = _resolveTreeRoot();
    if (pid <= 0) {
      _ledger.recordEnumerationFailure('invalid tree root pid');
      return false;
    }
    try {
      final tree = await treeProbe.enumerate(pid);
      if (tree == null) {
        _ledger.recordEnumerationFailure('process table unavailable');
        return false;
      }
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
      _ledger.merge(
        rootPid: pid,
        descendants: descendants,
        newIdentities: identities,
      );
      _ownedTree = SessionOwnedTree(
        rootPid: pid,
        identities: identities,
        descendantPids: descendants,
      );
      return true;
    } on Object catch (e) {
      _ledger.recordEnumerationFailure('enumerate failed: $e');
      return false;
    }
  }

  /// Spawns `oka run dev` (optionally under `xvfb-run -a`) and begins capture.
  static Future<OwnedDevSession> start({
    required String workspace,
    required List<String> dartInvocation,
    bool useXvfb = false,
    bool useSubreaperSupervisor = true,
    Map<String, String>? environment,
    String? workingDirectory,
    String? supervisorEntrypoint,
    Duration identityBudget = const Duration(seconds: 2),
    DevSessionSpawner spawn = defaultDevSessionSpawn,
    ProcessTreeProbe? treeProbe,
    ProcessLiveness? liveness,
    OwnedDevSessionStartController? startController,
  }) async {
    final dart = _dartVmExecutable();
    final cwd = workingDirectory ?? workspace;
    final useSupervisor = useSubreaperSupervisor && Platform.isLinux;
    final probe = treeProbe ?? const HostProcessTreeProbe();
    final live = liveness ?? const HostProcessLiveness();
    final sessionNonce = _freshSessionNonce();
    final env = Map<String, String>.from(environment ?? {});
    File? controlSink;
    String? controlPath;
    if (useSupervisor) {
      controlSink = await createSupervisorControlSink();
      controlPath = controlSink.path;
    }

    final proc = await _spawnWithOptionalSupervisor(
      executable: useXvfb ? 'xvfb-run' : dart,
      arguments:
          useXvfb ? ['-a', dart, ...dartInvocation] : dartInvocation,
      workingDirectory: cwd,
      environment: env,
      useSupervisor: useSupervisor,
      spawn: spawn,
      sessionNonce: sessionNonce,
      supervisorEntrypoint: supervisorEntrypoint,
      controlPath: controlPath,
    );
    startController?.onProcessSpawned(proc);

    final session = OwnedDevSession._(
      process: proc,
      sessionNonce: sessionNonce,
      treeProbe: probe,
      liveness: live,
      useSubreaperSupervisor: useSupervisor,
      controlSink: controlSink,
    );
    session._attachLineStreams();
    if (useSupervisor) {
      session._startControlPump();
    }
    startController?.onBootstrap(session);

    if (startController?.abortRequested == true) {
      await startController!.requestAbort();
      throw StateError('owned dev session start aborted after spawn');
    }

    try {
      session.identityToken = await session.liveness
          .identityToken(session._resolveTreeRoot())
          .timeout(identityBudget);
    } on Object {
      session.identityToken = null;
    }
    if (startController?.abortRequested == true) {
      await startController!.requestAbort();
      throw StateError('owned dev session start aborted after identity');
    }
    await session.snapshotOwnedTree();
    startController?.onSessionReady(session);
    if (startController?.abortRequested == true) {
      await session.teardown();
      throw StateError('owned dev session start aborted after snapshot');
    }
    return session;
  }

  Future<void> sendLine(String line) async {
    process.stdin.writeln(line);
    await process.stdin.flush();
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

  void _startControlPump() {
    _controlPumpTimer?.cancel();
    _controlPumpTimer = Timer.periodic(
      const Duration(milliseconds: 25),
      (_) => unawaited(_pumpControlFile()),
    );
  }

  Future<void> _pumpControlFile() async {
    final sink = _controlSink;
    if (sink == null) return;
    try {
      final length = await sink.length();
      if (length <= _controlReadOffset) return;
      final raf = await sink.open();
      try {
        await raf.setPosition(_controlReadOffset);
        final bytes = await raf.read(length - _controlReadOffset);
        _controlReadOffset = length;
        final chunk = utf8.decode(bytes);
        final update = parseSupervisorControlLines(chunk.split('\n'));
        if (update.workloadPid != null) {
          _workloadPid = update.workloadPid;
        }
        if (update.drainAck != null) {
          _drainAck = update.drainAck;
        }
        if (update.workloadExitCode != null) {
          _workloadExitFromControl = update.workloadExitCode;
        }
      } finally {
        await raf.close();
      }
    } on Object {
      // Control sink may disappear during teardown; ignore until exit.
    }
  }

  Future<void> _waitForSupervisorAck(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await _pumpControlFile();
      final ack = _drainAck;
      if (ack != null && ack.nonce == sessionNonce) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
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

  Future<({List<int> survivors, bool unknown})> _stopFromLedger() async {
    if (!_ledger.hasProvableOwnership) {
      return (survivors: <int>[], unknown: true);
    }

    final notesUnknown = <String>[];
    final root = _ledger.workloadRootPid ?? _resolveTreeRoot();
    if (root > 0 && await liveness.isAlive(root)) {
      final stop = await stopProcessTree(
        probe: treeProbe,
        liveness: liveness,
        rootPid: root,
        rootIdentityToken: _ledger.identities[root],
      );
      if (stop.notes.any((n) => n.contains('unavailable'))) {
        notesUnknown.addAll(stop.notes);
      }
      if (stop.survivors.isEmpty && stop.stopped) {
        return (survivors: <int>[], unknown: notesUnknown.isNotEmpty);
      }
      if (stop.survivors.isNotEmpty) {
        return (survivors: stop.survivors, unknown: notesUnknown.isNotEmpty);
      }
    }

    final survivors = <int>[];
    final ordered = [
      ..._ledger.descendantPids.toList().reversed,
      if (root > 0) root,
    ];
    for (final pid in ordered) {
      if (!_ledger.identities.containsKey(pid)) continue;
      final ok = await _killIfOwnedIdentity(pid, _ledger.identities[pid]);
      if (!ok && await liveness.isAlive(pid)) {
        survivors.add(pid);
      }
    }
    return (survivors: survivors, unknown: notesUnknown.isNotEmpty);
  }

  /// `q` + bounded wait with in-flight ownership refresh, then ledger stop.
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
    var sentQuit = false;
    final rootAliveBefore = await liveness.isAlive(process.pid);
    if (rootAliveBefore) {
      final snap = await snapshotOwnedTree();
      if (!snap) notes.add('pre-teardown snapshot: enumeration unavailable');
    }

    Future<void> tryQuitOnce() async {
      if (sentQuit) return;
      sentQuit = true;
      try {
        process.stdin.writeln('q');
        await process.stdin.flush();
      } on Object catch (e) {
        notes.add('stdin q: $e');
      }
    }

    if (rootAliveBefore) {
      await tryQuitOnce();
    }

    int? exitCode;
    final deadline = DateTime.now().add(quitGrace);
    while (DateTime.now().isBefore(deadline)) {
      if (useSubreaperSupervisor) {
        await _pumpControlFile();
      }
      if (await liveness.isAlive(process.pid)) {
        await snapshotOwnedTree();
      } else {
        try {
          exitCode = await process.exitCode.timeout(
            deadline.difference(DateTime.now()),
          );
        } on TimeoutException {
          notes.add('root exit wait timed out');
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    if (exitCode == null && !await liveness.isAlive(process.pid)) {
      try {
        exitCode = await process.exitCode;
      } on Object {
        exitCode = null;
      }
    } else if (exitCode == null && await liveness.isAlive(process.pid)) {
      notes.add('root did not exit within ${quitGrace.inSeconds}s after q');
    } else if (!rootAliveBefore) {
      notes.add('root already exited before teardown');
      try {
        exitCode = await process.exitCode;
      } on Object {
        exitCode = null;
      }
    }

    if (useSubreaperSupervisor) {
      await _waitForSupervisorAck(const Duration(seconds: 2));
      await _pumpControlFile();
    }

    _controlPumpTimer?.cancel();
    _controlPumpTimer = null;

    try {
      await process.stdin.close();
    } on Object catch (e) {
      notes.add('stdin close: $e');
    }

    await _stdoutSub.cancel();
    await _stderrSub.cancel();

    final stop = await _stopFromLedger();
    if (stop.unknown) {
      notes.add('ownership boundary unknown (enumeration or stop probe)');
    }
    if (_ledger.enumerationUnavailable) {
      notes.addAll(_ledger.errors);
    }

    final stillAlive = <int>[];
    for (final pid in _ledger.allTrackedPids) {
      if (await liveness.isAlive(pid)) stillAlive.add(pid);
    }
    if (await liveness.isAlive(process.pid)) {
      stillAlive.add(process.pid);
    }

    final mergedSurvivors = {...stop.survivors, ...stillAlive}.toList();
    var fixtureEscapedAlive = false;
    for (final entry in _fixtureEscapedByPid.entries) {
      if (await liveness.isAlive(entry.key)) {
        fixtureEscapedAlive = true;
        mergedSurvivors.add(entry.key);
        notes.add('fixture-reported escaped pid ${entry.key} still alive');
        final liveToken = await liveness.identityToken(entry.key);
        final expected = entry.value;
        if (liveToken != null && liveToken != expected) {
          notes.add(
            'fixture escaped pid ${entry.key} identity mismatch '
            '(expected token from fixture report)',
          );
        }
      }
    }

    var supervisorDrainVerified = true;
    if (useSubreaperSupervisor) {
      final ack = _drainAck;
      if (ack == null || ack.nonce != sessionNonce) {
        supervisorDrainVerified = false;
        notes.add('supervisor drain ack missing or nonce mismatch');
      } else if (!ack.settled || !ack.verified) {
        supervisorDrainVerified = false;
        notes.add(
          'supervisor drain ack failed settled=${ack.settled} '
          'verified=${ack.verified}',
        );
      } else if (ack.survivors.isNotEmpty) {
        supervisorDrainVerified = false;
        notes.add('supervisor drain ack survivors=${ack.survivors}');
      }
      if (exitCode != null && exitCode != 0) {
        supervisorDrainVerified = false;
        notes.add('supervisor wrapper exit nonzero ($exitCode)');
      }
      if (fixtureEscapedAlive) {
        supervisorDrainVerified = false;
        notes.add('fixture-reported escaped workload still alive');
      }
    }

    final uniqueSurvivors = mergedSurvivors.toSet().toList();
    final verified =
        !stop.unknown && _ledger.hasProvableOwnership && supervisorDrainVerified;
    final clean = verified && uniqueSurvivors.isEmpty;

    return OwnedDevSessionTeardown(
      clean: clean,
      verified: verified,
      exitCode: exitCode,
      workloadExitCode: _workloadExitFromControl,
      survivors: uniqueSurvivors,
      notes: notes,
    );
  }
}
