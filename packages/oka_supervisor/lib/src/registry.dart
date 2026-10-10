/// The advisory machine registry (ADR-0040 decisions 5–6).
///
/// One JSON record per component under
/// `<root>/records/<scope>/<componentId>.json`, written atomically
/// (temp + rename) **before** spawn — identity-before-side-effects.
/// Records are evidence, never authority: kill rights come from
/// [KillPolicy.spawned] lineage or explicit [KillPolicy.ceded], never
/// from registry presence.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Who may stop (and therefore restart) a recorded component.
enum KillPolicy {
  /// The supervisor spawned it; it owns the stop.
  spawned,

  /// A previous owner explicitly handed over kill rights.
  ceded,

  /// Hand-started or foreign: observe and report only, never signal.
  none,
}

/// The durable record of one supervised component.
final class SupervisorRecord {
  const SupervisorRecord({
    required this.componentId,
    required this.providerName,
    required this.shape,
    required this.revisionHash,
    required this.epoch,
    required this.killPolicy,
    required this.startedAt,
    required this.restartCount,
    required this.windowStartedAt,
    required this.trigger,
    this.pid,
    this.handle,
    this.identityToken,
    this.lastRun,
    this.port,
    this.outputs = const <String, Object?>{},
  });

  /// Tolerant parse; throws [FormatException] on structurally broken JSON
  /// (surfaced as a corrupt-record finding by the snapshot, never silent).
  SupervisorRecord.fromJson(final Map<String, Object?> json)
    : this(
        componentId: json['componentId']! as String,
        providerName: json['provider']! as String,
        shape: json['shape']! as String,
        revisionHash: json['revisionHash']! as String,
        epoch: json['epoch']! as int,
        killPolicy: KillPolicy.values.byName(json['killPolicy']! as String),
        startedAt: DateTime.parse(json['startedAt']! as String),
        restartCount: json['restartCount']! as int,
        windowStartedAt: DateTime.parse(json['windowStartedAt']! as String),
        trigger: json['trigger'] as String? ?? 'none',
        pid: json['pid'] as int?,
        handle: json['handle'] as String?,
        identityToken: json['identityToken'] as String?,
        lastRun: json['lastRun'] as String?,
        port: json['port'] as int?,
        outputs: (json['outputs'] as Map<String, Object?>?) ?? const {},
      );

  final String componentId;
  final String providerName;

  /// `service | job`.
  final String shape;

  /// Spec-content hash the record was created for; drift forces restart.
  final String revisionHash;

  /// Monotonic per-component generation, incremented before every start —
  /// a stale-epoch record can never authorize a signal.
  final int epoch;

  final KillPolicy killPolicy;
  final DateTime startedAt;

  /// Restarts performed within the current [SupervisionPolicy.restartWindow].
  final int restartCount;
  final DateTime windowStartedAt;

  /// Trigger summary ([Trigger.describe]) at record time.
  final String trigger;

  final int? pid;
  final String? handle;
  final String? identityToken;

  /// Jobs: `succeeded | failed | null` (unknown).
  final String? lastRun;

  /// Advisory; no allocator (ADR-0040 non-goals).
  final int? port;
  final Map<String, Object?> outputs;

  SupervisorRecord copyWith({
    final int? epoch,
    final KillPolicy? killPolicy,
    final DateTime? startedAt,
    final int? restartCount,
    final DateTime? windowStartedAt,
    final int? pid,
    final String? handle,
    final String? identityToken,
    final String? lastRun,
    final int? port,
    final Map<String, Object?>? outputs,
    final bool clearProcess = false,
  }) =>
      SupervisorRecord(
        componentId: componentId,
        providerName: providerName,
        shape: shape,
        revisionHash: revisionHash,
        epoch: epoch ?? this.epoch,
        killPolicy: killPolicy ?? this.killPolicy,
        startedAt: startedAt ?? this.startedAt,
        restartCount: restartCount ?? this.restartCount,
        windowStartedAt: windowStartedAt ?? this.windowStartedAt,
        trigger: trigger,
        pid: clearProcess ? null : (pid ?? this.pid),
        handle: clearProcess ? null : (handle ?? this.handle),
        identityToken: clearProcess
            ? null
            : (identityToken ?? this.identityToken),
        lastRun: lastRun ?? this.lastRun,
        port: port ?? this.port,
        outputs: outputs ?? this.outputs,
      );

  Map<String, Object?> toJson() => {
        'componentId': componentId,
        'provider': providerName,
        'shape': shape,
        'revisionHash': revisionHash,
        'epoch': epoch,
        'killPolicy': killPolicy.name,
        'startedAt': startedAt.toIso8601String(),
        'restartCount': restartCount,
        'windowStartedAt': windowStartedAt.toIso8601String(),
        'trigger': trigger,
        if (pid != null) 'pid': pid,
        if (handle != null) 'handle': handle,
        if (identityToken != null) 'identityToken': identityToken,
        if (lastRun != null) 'lastRun': lastRun,
        if (port != null) 'port': port,
        if (outputs.isNotEmpty) 'outputs': outputs,
      };
}

/// One scope's records plus any files that could not be parsed — corrupt
/// records are surfaced as findings, never silently dropped (the
/// ADR-0018 advisory-lease posture).
final class RegistrySnapshot {
  const RegistrySnapshot({
    required this.records,
    this.corruptPaths = const <String>[],
  });

  final List<SupervisorRecord> records;
  final List<String> corruptPaths;

  SupervisorRecord? operator [](final String componentId) {
    for (final record in records) {
      if (record.componentId == componentId) return record;
    }
    return null;
  }
}

/// Advisory, machine-wide record store. Two repos cannot collide: the
/// scope is a short hash of the canonical project root.
final class MachineRegistry {
  MachineRegistry({required this.root});

  /// The default machine root: `~/.oka/supervisor`.
  factory MachineRegistry.forMachine() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'HOME is not set; cannot locate the ~/.oka/supervisor registry',
      );
    }
    return MachineRegistry(root: p.join(home, '.oka', 'supervisor'));
  }

  /// Machine root (override in tests with a temp dir).
  final String root;

  /// Scope directory name for [projectRoot]: 12 hex chars of the SHA-1
  /// of the canonical absolute path.
  String scopeFor(final String projectRoot) {
    final canonical = p.canonicalize(projectRoot);
    final digest = sha1.convert(utf8.encode(canonical));
    return digest.toString().substring(0, 12);
  }

  File _file(final String scope, final String componentId) => File(
        p.join(root, 'records', scope, '$componentId.json'),
      );

  SupervisorRecord? read(final String scope, final String componentId) {
    final file = _file(scope, componentId);
    if (!file.existsSync()) return null;
    return SupervisorRecord.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
  }

  /// Atomic upsert: write to a unique temp file in the same directory,
  /// then rename over the target (the process-lease pattern).
  void upsert(final SupervisorRecord record, {required final String scope}) {
    final file = _file(scope, record.componentId);
    file.parent.createSync(recursive: true);
    File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp')
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(record.toJson()),
      )
      ..renameSync(file.path);
  }

  void delete(final String scope, final String componentId) {
    final file = _file(scope, componentId);
    if (file.existsSync()) file.deleteSync();
  }

  /// Every record in [scope], plus corrupt files as structured evidence.
  RegistrySnapshot snapshot(final String scope) {
    final dir = Directory(p.join(root, 'records', scope));
    if (!dir.existsSync()) return const RegistrySnapshot(records: []);
    final records = <SupervisorRecord>[];
    final corrupt = <String>[];
    final entities = dir.listSync().toList()
      ..sort((final a, final b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        records.add(
          SupervisorRecord.fromJson(
            jsonDecode(entity.readAsStringSync()) as Map<String, Object?>,
          ),
        );
      } on FormatException catch (_) {
        corrupt.add(entity.path);
      } on Object catch (_) {
        // A structurally broken record (bad JSON or wrong field types) is
        // evidence for the finding stream, never a crash.
        corrupt.add(entity.path);
      }
    }
    return RegistrySnapshot(records: records, corruptPaths: corrupt);
  }
}
