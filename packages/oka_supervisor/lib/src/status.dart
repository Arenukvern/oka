/// The read surface: records + desired state → one status view, shared by
/// the CLI, embedding apps, and mesh frames (ADR-0041).
///
/// Pure projection over a [RegistrySnapshot] and the desired state — it
/// never probes processes, never signals anything, and never writes. A
/// component appears once: from its record when present, from its spec
/// when only declared. Drift is reported, never acted on here; only
/// [Supervisor.converge] acts.
library;

import 'dart:convert';

import 'registry.dart';
import 'spec.dart';

/// One component's converged-so-far status.
final class ComponentStatus {
  const ComponentStatus({
    required this.componentId,
    required this.present,
    this.providerName,
    this.shape,
    this.killPolicy,
    this.epoch,
    this.restartCount,
    this.pid,
    this.revisionHash,
    this.desiredRevisionHash,
    this.lastRun,
    this.trigger,
    this.drifted = false,
  });

  /// A record exists for this component (it was started by a supervisor
  /// on this machine, this scope).
  final bool present;

  final String componentId;

  /// From the record when present, else the declaring spec.
  final String? providerName;
  final String? shape;

  /// Record-only: `spawned | ceded | none`; null when never started here.
  final String? killPolicy;

  /// Record-only generation counter.
  final int? epoch;
  final int? restartCount;
  final int? pid;

  /// The spec hash the record was created for; null when only declared.
  final String? revisionHash;

  /// The declaring spec's hash; null when no desired state names it.
  final String? desiredRevisionHash;

  /// Jobs: `succeeded | failed`; services and never-run: null.
  final String? lastRun;

  /// Trigger summary at record time, else the spec's.
  final String? trigger;

  /// Desired state names this id with a different
  /// [ComponentSpec.revisionHash] than the record — converge will restart.
  /// Meaningful only when both record and desired exist.
  final bool drifted;

  Map<String, Object?> toJson() => {
    'componentId': componentId,
    'present': present,
    if (providerName != null) 'provider': providerName,
    if (shape != null) 'shape': shape,
    if (killPolicy != null) 'killPolicy': killPolicy,
    if (epoch != null) 'epoch': epoch,
    if (restartCount != null) 'restartCount': restartCount,
    if (pid != null) 'pid': pid,
    if (revisionHash != null) 'revisionHash': revisionHash,
    if (desiredRevisionHash != null) 'desiredRevisionHash': desiredRevisionHash,
    if (lastRun != null) 'lastRun': lastRun,
    if (trigger != null) 'trigger': trigger,
    'drifted': drifted,
  };
}

/// Projects one status line per component: desired specs in declaration
/// order (record-backed or not), then record-only ids in id order.
List<ComponentStatus> projectStatus({
  required final RegistrySnapshot snapshot,
  final DesiredState? desired,
}) {
  final statuses = <ComponentStatus>[];
  final recorded = <String>{};

  for (final spec in desired?.specs ?? const <ComponentSpec>[]) {
    final record = snapshot[spec.id];
    recorded.add(spec.id);
    statuses.add(
      record == null
          ? ComponentStatus(
              componentId: spec.id,
              present: false,
              providerName: spec.providerName,
              shape: spec.policy.shape.name,
              desiredRevisionHash: spec.revisionHash,
              trigger: spec.trigger.describe(),
            )
          : _fromRecord(
              record,
              desiredRevisionHash: spec.revisionHash,
              drifted: record.revisionHash != spec.revisionHash,
            ),
    );
  }

  final recordOnly =
      snapshot.records
          .where((final record) => !recorded.contains(record.componentId))
          .map(_fromRecordOnly)
          .toList()
        ..sort((final a, final b) => a.componentId.compareTo(b.componentId));
  statuses.addAll(recordOnly);
  return statuses;
}

ComponentStatus _fromRecord(
  final SupervisorRecord record, {
  final String? desiredRevisionHash,
  final bool drifted = false,
}) => ComponentStatus(
  componentId: record.componentId,
  present: true,
  providerName: record.providerName,
  shape: record.shape,
  killPolicy: record.killPolicy.name,
  epoch: record.epoch,
  restartCount: record.restartCount,
  pid: record.pid,
  revisionHash: record.revisionHash,
  desiredRevisionHash: desiredRevisionHash,
  lastRun: record.lastRun,
  trigger: record.trigger,
  drifted: drifted,
);

ComponentStatus _fromRecordOnly(final SupervisorRecord record) =>
    _fromRecord(record);

/// Aligned plain-text rendering for terminals.
String renderStatus(final List<ComponentStatus> statuses) {
  const header = <String>[
    'ID',
    'PRESENT',
    'SHAPE',
    'PID',
    'EPOCH',
    'RESTARTS',
    'DRIFT',
    'TRIGGER',
  ];
  final rows = <List<String>>[
    header,
    for (final status in statuses)
      [
        status.componentId,
        if (status.present) 'yes' else 'no',
        status.shape ?? '-',
        '${status.pid ?? "-"}',
        '${status.epoch ?? "-"}',
        '${status.restartCount ?? "-"}',
        if (status.drifted) 'drifted' else '-',
        status.trigger ?? '-',
      ],
  ];
  final widths = <int>[
    for (var column = 0; column < header.length; column++)
      rows.fold(
        0,
        (final max, final row) =>
            row[column].length > max ? row[column].length : max,
      ),
  ];
  return [
    for (final row in rows)
      [
        for (var column = 0; column < row.length; column++)
          row[column].padRight(widths[column]),
      ].join('  ').trimRight(),
  ].join('\n');
}

/// One JSON document: statuses plus the snapshot's corrupt-record paths —
/// the wire shape for CLI `--json`, embedding UIs, and (later) mesh
/// supervisor-state frames (ADR-0041).
String statusJson({
  required final List<ComponentStatus> statuses,
  final List<String> corruptPaths = const <String>[],
}) => const JsonEncoder.withIndent('  ').convert({
  'statuses': [for (final status in statuses) status.toJson()],
  'corruptRecords': List<String>.of(corruptPaths),
});
