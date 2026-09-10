/// Process leases (ADR-0018 §1): the durable, on-disk record of a process
/// oka spawned (or adopted), stored under
/// `<project>/.oka_cache/processes/<id>.json` by [ProcessLeaseRegistry].
///
/// A lease is an **advisory record, not a supervisor** (ADR-0018 §1): no
/// daemon reads it and no refcounts hang off it — later oka runs reconcile
/// it against reality (liveness + identity, [LeaseLiveness]) so leaks
/// become visible instead of silent. The record shape mirrors the ADR §1
/// JSON exactly:
///
/// ```json
/// {
///   "id": "emulator-oka-emulator",
///   "pid": 48977,
///   "kind": "android-emulator",
///   "identity": {"avd": "oka-emulator", "serial": "emulator-5554"},
///   "scope": "ephemeral",
///   "ownership": "owned",
///   "owner_cmd": "oka run emulator",
///   "started_at": "2026-09-10T12:00:00.000Z",
///   "stop_hint": {"tool": "adb", "args": ["-s", "emulator-5554", "emu", "kill"]}
/// }
/// ```
library;

import 'dart:convert';

import 'package:from_json_to_json/from_json_to_json.dart';
import 'package:meta/meta.dart';

/// Reserved [ProcessLease.identity] key carrying the platform process
/// start-time token — the identity-over-pid anchor (ADR-0018 §1).
///
/// Spawn steps record it from [ProcessLiveness.identityToken] when the
/// lease is written; the kill gate ([verifyKillIdentity]) compares it with
/// the live token before any signal is sent, so a recycled pid is never
/// mistaken for the leased process. The value is platform-defined plain
/// text (`ps -o lstart=` on macOS, `/proc/<pid>/stat` starttime on Linux).
const processLeasePidTokenKey = 'oka:pid_token';

/// Lifecycle scope of a leased process (ADR-0018 §3): declared on the
/// spawn target — a parameter, not a type hierarchy.
enum LeaseScope {
  /// Die when the run ends — normal exit, failure, signal (CI/agent
  /// default).
  ephemeral,

  /// Die when the owning session ends; survives rebuilds within `oka dev`.
  session,

  /// Survives the run; must be discoverable and stoppable via the CLI
  /// (explicit opt-in).
  persistent;

  /// Wire label — the ADR §1 JSON value (`ephemeral`/`session`/`persistent`).
  String get label => name;

  /// Decodes a wire label; unknown values throw (fail-closed, the registry
  /// never guesses a scope).
  static LeaseScope fromLabel(final String label) => LeaseScope.values
      .firstWhere((final s) => s.label == label, orElse: () => throw _unknownLabel('LeaseScope', label, LeaseScope.values.map((final s) => s.label)));
}

/// Ownership of a leased process (ADR-0018 §3): [owned] = this run spawned
/// it; [borrowed] = idempotent reuse found it running. **Teardown stops
/// only `owned` leases** — killing a borrowed session would break the
/// reuse contract and whatever other terminal owns it.
enum LeaseOwnership {
  /// This run spawned the process (recorded by the spawn step).
  owned,

  /// Idempotent reuse found the process already running.
  borrowed;

  /// Wire label — the ADR §1 JSON value (`owned`/`borrowed`).
  String get label => name;

  /// Decodes a wire label; unknown values throw (fail-closed).
  static LeaseOwnership fromLabel(final String label) => LeaseOwnership.values
      .firstWhere((final o) => o.label == label, orElse: () => throw _unknownLabel('LeaseOwnership', label, LeaseOwnership.values.map((final o) => o.label)));
}

FormatException _unknownLabel(
  final String type,
  final String label,
  final Iterable<String> accepted,
) =>
    FormatException(
      'Unknown $type label "$label" — accepted: ${accepted.join(', ')}.',
    );

/// The graceful stop path for a leased process (ADR-0018 §1 `stop_hint`).
///
/// Carries the *graceful* command — e.g. `adb -s <serial> emu kill`, not
/// SIGKILL — so teardown (L1) can run graceful-first before escalating.
/// pid 0 in [args] means "pid unknown" (borrowed leases adopted by
/// semantic discovery record `pid: 0`).
@immutable
final class LeaseStopHint {
  /// Creates a stop hint.
  const LeaseStopHint({required this.tool, this.args = const []});

  /// Decodes from the `stop_hint` JSON object.
  factory LeaseStopHint.fromJson(final Object? json) {
    final map = jsonDecodeMap(json);
    return LeaseStopHint(
      tool: jsonDecodeString(map['tool']),
      args: jsonDecodeList(map['args']).cast<String>(),
    );
  }

  /// The graceful tool, e.g. `'adb'` or `'kill'`.
  final String tool;

  /// The tool's arguments (may reference the leased pid).
  final List<String> args;

  /// Encodes to the `stop_hint` JSON object.
  Map<String, Object?> toJson() => {'tool': tool, 'args': args};

  @override
  bool operator ==(final Object other) =>
      other is LeaseStopHint && other.tool == tool && _listEquals(other.args, args);

  @override
  int get hashCode => Object.hash(tool, Object.hashAll(args));

  @override
  String toString() => args.isEmpty ? tool : '$tool ${args.join(' ')}';
}

/// A durable record of one process oka spawned (or adopted), per ADR-0018
/// §1. Immutable value; JSON at the registry boundary only.
///
/// Spawn steps create leases; the registry stores them; teardown and the
/// reconcile sweep consume them. The lifecycle guide for the full picture:
/// `docs/guides/process_lifecycle.mdx`.
///
/// Recording a spawn (the pattern every spawn step follows):
///
/// ```dart
/// final liveness = const HostProcessLiveness();
/// final registry = ProcessLeaseRegistry.forProject(ctx.projectPath);
/// final process = await Process.start('emulator', ['-avd', avdName]);
/// await registry.upsert(ProcessLease(
///   id: 'emulator-$avdName',
///   pid: process.pid,
///   kind: 'android-emulator',
///   // Identity over pid: the start-time token makes later kills
///   // pid-recycling-safe (ADR-0018 §1).
///   identity: {
///     'avd': avdName,
///     processLeasePidTokenKey:
///         await liveness.identityToken(process.pid) ?? '',
///   },
///   scope: LeaseScope.ephemeral,
///   ownership: LeaseOwnership.owned,
///   ownerCmd: 'oka run emulator',
///   startedAt: DateTime.now().toUtc(),
///   stopHint: LeaseStopHint(
///     tool: 'adb',
///     args: ['-s', serial, 'emu', 'kill'], // graceful path
///   ),
/// ));
/// ```
@immutable
final class ProcessLease {
  /// Creates a lease record.
  const ProcessLease({
    required this.id,
    required this.pid,
    required this.kind,
    required this.scope,
    required this.ownership,
    required this.ownerCmd,
    required this.startedAt,
    required this.stopHint,
    this.identity = const {},
  });

  /// Decodes from the ADR §1 JSON shape.
  factory ProcessLease.fromJson(final Object? json) {
    final map = jsonDecodeMap(json);
    final identityMap = jsonDecodeMap(map['identity']);
    return ProcessLease(
      id: jsonDecodeString(map['id']),
      pid: jsonDecodeInt(map['pid']),
      kind: jsonDecodeString(map['kind']),
      identity: identityMap.map(
        (final k, final v) => MapEntry(k, jsonDecodeString(v)),
      ),
      scope: LeaseScope.fromLabel(jsonDecodeString(map['scope'])),
      ownership: LeaseOwnership.fromLabel(jsonDecodeString(map['ownership'])),
      ownerCmd: jsonDecodeString(map['owner_cmd']),
      startedAt: DateTime.parse(jsonDecodeString(map['started_at'])).toUtc(),
      stopHint: LeaseStopHint.fromJson(map['stop_hint']),
    );
  }

  /// Decodes from a JSON string.
  factory ProcessLease.fromJsonString(final String source) =>
      ProcessLease.fromJson(jsonDecode(source));

  /// Stable identifier, e.g. `emulator-oka-emulator` — also the on-disk
  /// file name (`<id>.json`). Kind + instance name, unique per process.
  final String id;

  /// OS process id. `0` means "unknown" (borrowed leases adopted by
  /// semantic discovery — adb serial / CDP port — have no pid).
  final int pid;

  /// Session kind, e.g. `'android-emulator'`, `'chrome-session'`.
  final String kind;

  /// Semantic identity (avd, serial, cdp port, …) plus the reserved
  /// [processLeasePidTokenKey] start-time token when it was obtainable.
  final Map<String, String> identity;

  /// Lifecycle scope (ADR-0018 §3).
  final LeaseScope scope;

  /// Ownership (ADR-0018 §3): teardown stops only `owned` leases.
  final LeaseOwnership ownership;

  /// The command that spawned (or adopted) it, e.g. `oka run emulator`.
  final String ownerCmd;

  /// When the lease was written (UTC).
  final DateTime startedAt;

  /// The graceful stop path ([LeaseStopHint]).
  final LeaseStopHint stopHint;

  /// Encodes to the ADR §1 JSON shape.
  Map<String, Object?> toJson() => {
        'id': id,
        'pid': pid,
        'kind': kind,
        'identity': identity,
        'scope': scope.label,
        'ownership': ownership.label,
        'owner_cmd': ownerCmd,
        'started_at': startedAt.toUtc().toIso8601String(),
        'stop_hint': stopHint.toJson(),
      };

  /// Encodes to a JSON string (the exact bytes the registry writes).
  String toJsonString() => jsonEncode(toJson());

  /// Returns a copy with the given fields replaced. Used by the adopt path
  /// to flip [ownership] to `borrowed` (ADR-0018 §3: adopting a lease
  /// flips its ownership; nothing else changes).
  ProcessLease copyWith({
    required final Map<String, String> identity,
    final int? pid,
    final LeaseOwnership? ownership,
    final LeaseStopHint? stopHint,
  }) =>
      ProcessLease(
        id: id,
        pid: pid ?? this.pid,
        kind: kind,
        identity: identity,
        scope: scope,
        ownership: ownership ?? this.ownership,
        ownerCmd: ownerCmd,
        startedAt: startedAt,
        stopHint: stopHint ?? this.stopHint,
      );

  @override
  bool operator ==(final Object other) =>
      other is ProcessLease &&
      other.id == id &&
      other.pid == pid &&
      other.kind == kind &&
      _mapEquals(other.identity, identity) &&
      other.scope == scope &&
      other.ownership == ownership &&
      other.ownerCmd == ownerCmd &&
      other.startedAt == startedAt &&
      other.stopHint == stopHint;

  @override
  int get hashCode => Object.hash(
        id,
        pid,
        kind,
        Object.hashAllUnordered(identity.entries),
        scope,
        ownership,
        ownerCmd,
        startedAt,
        stopHint,
      );

  @override
  String toString() =>
      'ProcessLease($id, pid $pid, $kind, ${ownership.label}/${scope.label})';
}

bool _listEquals(final List<String> a, final List<String> b) =>
    a.length == b.length && a.indexed.every((final e) => b[e.$1] == e.$2);

bool _mapEquals(final Map<String, String> a, final Map<String, String> b) =>
    a.length == b.length && a.entries.every((final e) => b[e.key] == e.value);
