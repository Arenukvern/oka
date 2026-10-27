import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'observation_budget.dart';
import 'owned_process_launch_spec.dart';
import 'owned_process_session_handle.dart';
import 'owned_session_mode.dart';
import 'p1_leader_locator.dart';
import 'p1_protocol.dart';
import 'posix_group_observation.dart';
import 'process_identity_token.dart';
import 'process_session_backend.dart';
import 'session_control_binding.dart';
import 'settlement.dart';
import 'stop_receipt.dart';

final class OwnedProcessLaunchException implements Exception {
  OwnedProcessLaunchException(this.message);

  final String message;

  @override
  String toString() => 'OwnedProcessLaunchException: $message';
}

final class _PosixPerlSessionRuntime {
  _PosixPerlSessionRuntime({
    required this.runtimeKey,
    required this.process,
    required this.binding,
    required this.marker,
    required this.startTime,
    required this.spec,
    required this.budget,
  });

  final String runtimeKey;
  final Process process;
  final SessionControlBinding binding;
  final String marker;
  int sessionId = 0;
  final DateTime startTime;
  final OwnedProcessLaunchSpec spec;
  final ObservationBudget budget;

  Socket? controlSocket;
  IOSink? controlSink;
  bool ready = false;
  bool rootExited = false;
  bool externallyStopped = false;
  bool groupGone = false;
  bool settleRequested = false;
  bool clearedPsObservationStop = false;
  bool deferSigkillEscalation = false;
  bool groupKilled = false;
  int? reportedWaitStatus;
  String? unsettledReason;
  String? controlFailure;
  final settleAcknowledged = Completer<void>();
  final Set<int> observedMembers = <int>{};

  ProcessIdentityToken identity() => ProcessIdentityToken(
    pid: process.pid,
    startTime: startTime,
    marker: marker,
    sessionId: sessionId,
  );

  Future<void> disposeControl() async {
    try {
      await controlSink?.close();
    } on Object {
      // Best-effort.
    }
    try {
      await controlSocket?.close();
    } on Object {
      // Best-effort.
    }
    await binding.dispose();
  }
}

final _runtimes = <String, _PosixPerlSessionRuntime>{};

String _generateMarker() {
  final r = Random.secure();
  return 'oka_${r.nextInt(1 << 32)}_${r.nextInt(1 << 32)}';
}

Future<OwnedProcessSessionHandle> launchPosixPerlSession(
  OwnedProcessLaunchSpec spec,
) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw OwnedProcessLaunchException('posix-perl requires Linux or macOS');
  }
  spec.observationBudget.validatePositive();
  if (spec.protocol != 1) {
    throw OwnedProcessLaunchException('unsupported protocol ${spec.protocol}');
  }
  if (spec.mode != OwnedSessionMode.owned) {
    throw OwnedProcessLaunchException('unsupported mode ${spec.mode.wireName}');
  }
  final perl = resolveSystemPerlPath();
  if (perl == null) {
    throw OwnedProcessLaunchException('system perl not found');
  }
  final leaderPath = await resolveOwnedSessionP1LeaderPath();
  if (!File(leaderPath).existsSync()) {
    throw OwnedProcessLaunchException('leader not found: $leaderPath');
  }
  final binding = await SessionControlBinding.bind();
  if (binding == null) {
    throw OwnedProcessLaunchException('control socket bind failed');
  }
  final marker = spec.marker ?? _generateMarker();
  final leaderArgs = <String>[
    leaderPath,
    '--protocol',
    '${spec.protocol}',
    '--mode',
    spec.mode.wireName,
    '--marker',
    marker,
    '--control',
    binding.socketPath,
  ];
  final hook = spec.gracefulCleanupHook;
  if (hook != null) {
    final secs = hook.timeout.inSeconds;
    if (secs < 1 || secs > 300) {
      throw ArgumentError.value(
        hook.timeout,
        'gracefulCleanupHook.timeout',
        'must be 1–300 whole seconds',
      );
    }
    leaderArgs.addAll([
      '--graceful',
      hook.executable,
      '--graceful-timeout',
      '$secs',
    ]);
  }
  leaderArgs.addAll(['--', spec.executable, ...spec.arguments]);

  final env = <String, String>{...Platform.environment, ...spec.environment};
  final launchInstant = DateTime.now();
  late final Process process;
  try {
    process = await Process.start(
      perl,
      leaderArgs,
      workingDirectory: spec.workingDirectory,
      environment: env,
      includeParentEnvironment: false,
    );
  } on ProcessException catch (e) {
    await binding.dispose();
    throw OwnedProcessLaunchException(e.message);
  }

  final runtimeKey = '${process.pid}_${launchInstant.microsecondsSinceEpoch}';
  final runtime = _PosixPerlSessionRuntime(
    runtimeKey: runtimeKey,
    process: process,
    binding: binding,
    marker: marker,
    startTime: launchInstant,
    spec: spec,
    budget: spec.observationBudget,
  );
  _runtimes[runtimeKey] = runtime;

  final startup = Completer<void>();
  final channelStarted = Completer<void>();
  final header = <int>[];
  var headerPending = true;

  void failStartup(String message) {
    if (!startup.isCompleted) {
      startup.completeError(OwnedProcessLaunchException(message));
    }
  }

  process.stderr.listen(
    (chunk) {
      if (!headerPending) return;
      header.addAll(chunk);
      final end = header.indexOf(10);
      if (end < 0) return;
      final first = utf8.decode(header.sublist(0, end), allowMalformed: true);
      final ready = OwnedSessionReadyLine.tryParse(first);
      if (ready == null || ready.marker != marker) {
        failStartup(
          ready == null
              ? 'invalid ready line: $first'
              : 'ready marker mismatch',
        );
        headerPending = false;
        return;
      }
      runtime.sessionId = ready.sessionId;
      runtime.ready = true;
      headerPending = false;
      if (!startup.isCompleted) startup.complete();
    },
    onDone: () {
      if (!startup.isCompleted) {
        failStartup('leader stderr closed before ready');
      }
    },
    onError: (_) => failStartup('leader stderr error'),
  );

  unawaited(() async {
    try {
      final socket = await binding.firstConnection.timeout(
        runtime.budget.duration,
      );
      runtime.controlSocket = socket;
      runtime.controlSink = socket;
      unawaited(_listenControl(runtime, channelStarted, marker: marker));
    } on Object {
      runtime.controlFailure = 'control accept failed';
      if (!channelStarted.isCompleted) channelStarted.complete();
      if (!startup.isCompleted) {
        startup.completeError(
          OwnedProcessLaunchException('control accept failed'),
        );
      }
    }
  }());

  process.exitCode.then((_) {
    runtime.rootExited = true;
  });

  try {
    await startup.future.timeout(runtime.budget.duration);
    await channelStarted.future.timeout(runtime.budget.duration);
  } on TimeoutException {
    await runtime.disposeControl();
    process.kill(ProcessSignal.sigkill);
    _runtimes.remove(runtimeKey);
    throw OwnedProcessLaunchException('launch timed out waiting for started');
  } on OwnedProcessLaunchException {
    await runtime.disposeControl();
    process.kill(ProcessSignal.sigkill);
    _runtimes.remove(runtimeKey);
    rethrow;
  }

  if (runtime.controlFailure != null) {
    await runtime.disposeControl();
    process.kill(ProcessSignal.sigkill);
    _runtimes.remove(runtimeKey);
    throw OwnedProcessLaunchException(runtime.controlFailure!);
  }

  unawaited(_watchAutoSettle(runtime));

  return OwnedProcessSessionHandle(
    leaderIdentity: runtime.identity(),
    backendKind: ProcessSessionBackendKind.posixPerl,
    launchSpec: spec,
    controlSocketPath: binding.socketPath,
    marker: marker,
    sessionId: runtime.sessionId,
    runtimeKey: runtimeKey,
  );
}

Future<void> _listenControl(
  _PosixPerlSessionRuntime runtime,
  Completer<void> channelStarted, {
  required String marker,
}) async {
  final socket = runtime.controlSocket;
  if (socket == null) return;
  final buffer = <int>[];
  var authenticated = false;
  try {
    await for (final chunk in socket) {
      buffer.addAll(chunk);
      while (true) {
        final index = buffer.indexOf(10);
        if (index < 0) break;
        final line = utf8.decode(
          buffer.sublist(0, index),
          allowMalformed: true,
        );
        buffer.removeRange(0, index + 1);
        if (!authenticated) {
          if (line != marker) {
            runtime.controlFailure = 'control authentication failed';
            if (!channelStarted.isCompleted) channelStarted.complete();
            return;
          }
          authenticated = true;
          continue;
        }
        _handleControlLine(runtime, line, channelStarted);
      }
    }
  } on Object {
    // Socket closed.
  }
}

void _handleControlLine(
  _PosixPerlSessionRuntime runtime,
  String line,
  Completer<void> channelStarted,
) {
  final status = parseOwnedSessionStatusLine(line);
  if (status is StatusStarted) {
    if (!channelStarted.isCompleted) channelStarted.complete();
    return;
  }
  if (status is StatusSettled) {
    if (!runtime.settleAcknowledged.isCompleted) {
      runtime.settleAcknowledged.complete();
    }
    return;
  }
  if (status is StatusExit) {
    runtime.reportedWaitStatus = status.waitStatus;
    unawaited(_maybeSettleAfterTargetExit(runtime));
    return;
  }
  if (status is StatusUnsettled) {
    runtime.unsettledReason = status.reason;
    return;
  }
  if (status is StatusKilledGroup) {
    runtime.groupKilled = true;
    return;
  }
}

Future<void> _maybeSettleAfterTargetExit(
  _PosixPerlSessionRuntime runtime,
) async {
  if (runtime.externallyStopped ||
      runtime.reportedWaitStatus == null ||
      runtime.settleRequested) {
    return;
  }
  final members = await _ownedGroupMembers(runtime);
  if (members == null) return;
  if (!await _onlyLeaderRemainsLive(members, runtime)) return;
  await _requestSettle(runtime);
}

Future<void> _watchAutoSettle(_PosixPerlSessionRuntime runtime) async {
  while (!runtime.settleRequested && !runtime.externallyStopped) {
    if (runtime.reportedWaitStatus != null) {
      final members = await _ownedGroupMembers(runtime);
      if (members != null && await _onlyLeaderRemainsLive(members, runtime)) {
        await _requestSettle(runtime);
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Set<int>?> _ownedGroupMembers(_PosixPerlSessionRuntime runtime) async {
  if (runtime.groupGone) return <int>{};
  final rows = await readProcessGroupRows();
  if (rows == null) return null;
  final members = <int>{
    for (final (pid, _, pgid, stat) in rows)
      if (runtime.ready && pgid == runtime.process.pid && !stat.contains('Z'))
        pid,
  };
  if (runtime.ready && runtime.rootExited && members.isEmpty) {
    runtime.groupGone = true;
  }
  runtime.observedMembers
    ..clear()
    ..addAll(members);
  return members;
}

Future<bool> _onlyLeaderRemainsLive(
  Set<int> members,
  _PosixPerlSessionRuntime runtime,
) async {
  var liveLeader = false;
  for (final pid in members) {
    if (await pidAlive(pid) == false) continue;
    if (pid != runtime.process.pid) return false;
    liveLeader = true;
  }
  return liveLeader;
}

Future<void> _requestSettle(_PosixPerlSessionRuntime runtime) async {
  if (runtime.externallyStopped || runtime.settleRequested) return;
  runtime.settleRequested = true;
  await _sendControl(runtime, OwnedSessionControlCommand.settle);
}

Future<bool> _sendControl(
  _PosixPerlSessionRuntime runtime,
  OwnedSessionControlCommand command,
) async {
  final sink = runtime.controlSink;
  if (sink == null) return false;
  try {
    sink.writeln(command.wireName);
    await sink.flush();
    return true;
  } on Object {
    return false;
  }
}

Future<StopReceipt> stopPosixPerlSession(
  OwnedProcessSessionHandle handle,
) async {
  final runtime = _runtimes[handle.runtimeKey];
  if (runtime == null) {
    return StopReceipt(
      identity: handle.leaderIdentity,
      settlement: const SettlementUnsettled('session not registered'),
    );
  }
  if (!_identityMatches(handle.leaderIdentity, runtime.identity())) {
    return StopReceipt(
      identity: handle.leaderIdentity,
      settlement: const SettlementUnsettled('identity mismatch'),
    );
  }
  runtime.externallyStopped = true;
  final grace = runtime.budget.duration;
  await _ownedGroupMembers(runtime);
  await _stopOwnedGroup(runtime, grace: grace);
  await _waitForLeaderShutdown(runtime, grace);
  try {
    await runtime.process.exitCode.timeout(grace);
  } on TimeoutException {
    // Leader may still be winding down; settlement uses wire evidence below.
  }

  SettlementResult settlement;
  if (runtime.unsettledReason != null) {
    settlement = SettlementUnsettled(runtime.unsettledReason!);
  } else if (runtime.settleAcknowledged.isCompleted ||
      runtime.groupKilled ||
      runtime.rootExited ||
      await pidAlive(runtime.process.pid) == false) {
    final ws = runtime.reportedWaitStatus;
    if (ws != null) {
      final mapped = waitStatusToSettlement(ws);
      settlement = SettlementSettled(
        exitCode: mapped.exitCode,
        signal: mapped.signal,
      );
    } else if (runtime.groupKilled) {
      settlement = const SettlementSettled(signal: 9);
    } else {
      settlement = const SettlementSettled(exitCode: 0);
    }
  } else {
    settlement = const SettlementUnsettled('settle not acknowledged');
  }

  await runtime.disposeControl();
  _runtimes.remove(handle.runtimeKey);

  return StopReceipt(identity: runtime.identity(), settlement: settlement);
}

bool _identityMatches(ProcessIdentityToken a, ProcessIdentityToken b) =>
    a.pid == b.pid &&
    a.startTime == b.startTime &&
    a.marker == b.marker &&
    a.sessionId == b.sessionId;

Future<void> _stopOwnedGroup(
  _PosixPerlSessionRuntime runtime, {
  required Duration grace,
}) async {
  final signaled = <int>{};
  Future<bool> signal(ProcessSignal value) async {
    final snapshot = Set<int>.from(runtime.observedMembers);
    final members = await _ownedGroupMembers(runtime);
    final command = value == ProcessSignal.sigkill
        ? OwnedSessionControlCommand.kill
        : OwnedSessionControlCommand.term;
    if (members == null) {
      if (runtime.rootExited) return false;
      if (runtime.ready && runtime.clearedPsObservationStop) return false;
      if (snapshot.isNotEmpty) signaled.addAll(snapshot);
      if (runtime.ready && !runtime.rootExited) {
        return await _sendControl(runtime, command);
      }
      return signaled.isNotEmpty;
    }
    if (members.isEmpty) {
      if (!runtime.ready && !runtime.rootExited) {
        if (runtime.process.kill(value)) signaled.add(runtime.process.pid);
      } else if (!runtime.rootExited && snapshot.isNotEmpty) {
        signaled.addAll(snapshot);
        runtime.clearedPsObservationStop = true;
        runtime.deferSigkillEscalation = true;
        return true;
      } else if (runtime.ready && !runtime.rootExited) {
        return await _sendControl(runtime, command);
      }
      return signaled.isNotEmpty;
    }
    if (value == ProcessSignal.sigkill &&
        await _onlyLeaderRemainsLive(members, runtime)) {
      return signaled.isNotEmpty;
    }
    signaled.addAll(members);
    if (!runtime.rootExited && await _sendControl(runtime, command)) {
      return true;
    }
    if (runtime.rootExited) return false;
    if (!runtime.ready) {
      if (runtime.process.kill(value)) signaled.add(runtime.process.pid);
      return true;
    }
    return false;
  }

  await signal(ProcessSignal.sigterm);
  var end = DateTime.now().add(grace);
  while (DateTime.now().isBefore(end)) {
    final members = await _ownedGroupMembers(runtime);
    if (members != null && members.isEmpty && runtime.rootExited) {
      break;
    }
    if (runtime.reportedWaitStatus != null) {
      final members = await _ownedGroupMembers(runtime);
      if (members != null && await _onlyLeaderRemainsLive(members, runtime)) {
        await _requestSettle(runtime);
        break;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (!runtime.clearedPsObservationStop) {
    await signal(ProcessSignal.sigkill);
  }
  end = DateTime.now().add(grace);
  while (DateTime.now().isBefore(end)) {
    if (runtime.rootExited) break;
    final alive = await pidAlive(runtime.process.pid);
    if (alive == false) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (!runtime.settleRequested &&
      runtime.reportedWaitStatus != null &&
      !runtime.rootExited) {
    final members = await _ownedGroupMembers(runtime);
    if (members != null && await _onlyLeaderRemainsLive(members, runtime)) {
      await _requestSettle(runtime);
    }
  }
  if (!runtime.settleAcknowledged.isCompleted) {
    try {
      await runtime.settleAcknowledged.future.timeout(grace);
    } on TimeoutException {
      // Reported below as unsettled if needed.
    }
  }
}

Future<void> _waitForLeaderShutdown(
  _PosixPerlSessionRuntime runtime,
  Duration grace,
) async {
  final deadline = DateTime.now().add(grace);
  while (DateTime.now().isBefore(deadline)) {
    if (runtime.groupKilled || runtime.settleAcknowledged.isCompleted) {
      return;
    }
    final alive = await pidAlive(runtime.process.pid);
    if (alive == false) {
      runtime.rootExited = true;
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
