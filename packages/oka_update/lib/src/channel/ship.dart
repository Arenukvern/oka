/// The invisible authoring rule (ADR-0037 §1): a patch the developer
/// writes by hand is a bug. Everything below the unit declaration is
/// derived — manifests from the tree, eligibility from the manifests,
/// deltas from the changed units, the channel tree from the plan. The
/// developer's whole loop is `oka ship`; the receipt is the interface.
library;

import 'dart:convert';
import 'dart:io';

import '../live/session.dart'
    show DeltaRequest, UnitDeltaCompiler;
import '../patch_plan.dart';
import '../unit_spec.dart';
import 'channel_manifest.dart';
import 'channel_source.dart' show decodeChannelJson;
import 'signing.dart' show ChannelSigner;

/// The `oka ship` receipt (ADR-0037 §1: every derivation prints one
/// receipt line; the receipt is the interface).
class ShipReceipt {
  const ShipReceipt({
    required this.ok,
    required this.mode,
    required this.revision,
    required this.baseline,
    this.parentRevision,
    this.plan,
    this.deltas = const [],
    this.snapshot,
    this.reasons = const [],
    this.dirtyTree = false,
  });

  final bool ok;

  /// `baseline` | `patch` | `nothing-to-ship` | `refused` | `dry-run` |
  /// `failed`.
  final String mode;
  final String revision;
  final String baseline;
  final String? parentRevision;
  final RecordedPlan? plan;
  final List<ShipDelta> deltas;
  final UnitArtifact? snapshot;
  final List<String> reasons;

  /// True when the git working tree had uncommitted changes.
  final bool dirtyTree;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'mode': mode,
        'revision': revision,
        'baseline': baseline,
        if (parentRevision != null) 'parent': parentRevision,
        'plan': plan?.toJson(),
        'deltas': [for (final d in deltas) d.toJson()],
        'snapshot': snapshot?.toJson(),
        'reasons': reasons,
        'dirtyTree': dirtyTree,
      };

  /// One human line per derivation (the receipt IS the interface,
  /// ADR-0035's Ive verdict).
  String describe() {
    final b = StringBuffer()
      ..writeln('ship ${ok ? 'OK' : 'REFUSED'} — $mode at $revision');
    if (parentRevision != null) b.writeln('  parent: $parentRevision');
    final units = plan?.changedUnits ?? const <String>[];
    if (units.isNotEmpty) b.writeln('  units: ${units.join(', ')}');
    for (final d in deltas) {
      b.writeln('  delta `${d.unit}`: ${d.artifact.bytes}B '
          '(${d.changedFiles.join(', ')})');
    }
    if (snapshot != null) b.writeln('  snapshot: ${snapshot!.file}');
    if (dirtyTree) b.writeln('  note: dirty tree (stamped, not refused)');
    for (final r in reasons) {
      b.writeln('  - $r');
    }
    return b.toString();
  }
}

/// One compiled delta staged into the channel tree.
class ShipDelta {
  const ShipDelta({
    required this.unit,
    required this.revision,
    required this.artifact,
    required this.changedFiles,
  });

  final String unit;
  final String revision;
  final UnitArtifact artifact;
  final List<String> changedFiles;

  Map<String, Object?> toJson() => {
        'unit': unit,
        'revision': revision,
        'artifact': artifact.toJson(),
        'changedFiles': changedFiles,
      };
}

/// Exception whose message names the fix (the honest refusal).
class ShipException implements Exception {
  ShipException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Derives a whole-revision snapshot artifact from the build pipeline and
/// returns its local path. `oka ship --snapshot-from-build` wires this —
/// the snapshot a threshold client falls back to is built, never
/// hand-picked (ADR-0037 G-AC6).
typedef SnapshotBuilder = Future<String> Function();

/// The chain a client at [fromRevision] (or the baseline) would have to
/// apply to reach the channel head: cumulative delta bytes and revision
/// count, walked from [head] down the `parent` links. This is the
/// publisher-side projection of the client-side `planChain` thresholds —
/// when it would overrun the pointer's policy, the next ship attaches a
/// head snapshot instead of shipping clients an unusable chain.
({int bytes, int revisions}) chainLoad(
    String channelDir, RevisionNode head, String fromRevision) {
  var bytes = 0;
  var revisions = 0;
  RevisionNode? node = head;
  while (node != null) {
    if (node.revision == fromRevision) break;
    for (final unit in node.units.values) {
      bytes += unit.delta?.bytes ?? 0;
    }
    if (node.parent == null) break; // the baseline seed carries no steps
    revisions++;
    final parentFile = File('$channelDir/manifests/${node.parent}.json');
    if (!parentFile.existsSync()) break;
    node = RevisionNode.fromJson(
        decodeChannelJson(parentFile.readAsBytesSync(), node.parent!));
  }
  return (bytes: bytes, revisions: revisions);
}

/// Derives the next revision node from the working tree: sha256 per
/// unit-library file, declaration-signature fingerprints (prototype-
/// grade; ADR-0034 G4 replaces them with analyzer-backed ones — the
/// failure mode is fail-closed: a mis-classification refuses, it never
/// ships a wrong patch), and a core digest over every dart file no unit
/// claims.
RevisionNode deriveNode({
  required String revision,
  required String? parent,
  required String baseline,
  required String root,
  required List<PatchUnit> units,
  RecordedPlan? plan,
  UnitArtifact? snapshot,
}) {
  // Declared libraries are app-root-relative and may live in workspace
  // packages (`packages/<pkg>/lib/src/…`), not only under the app's own
  // lib/ — real apps patch real packages (last_answer's engine units).
  final unitOfPath = <String, String>{};
  for (final unit in units) {
    for (final lib in unit.libraries) {
      if (!File('$root/$lib').existsSync()) {
        throw ShipException(
            'unit `${unit.name}` library missing: $lib — fix the '
            'declaration (directories are not units; declare .dart files)');
      }
      unitOfPath[lib] = unit.name;
    }
  }
  String? unitOf(String path) {
    if (unitOfPath.containsKey(path)) return unitOfPath[path];
    for (final entry in unitOfPath.entries) {
      if (path.endsWith('/${entry.key}')) return entry.value;
    }
    return null;
  }

  // Core scan roots: the app's lib/ plus the lib/ of every package a
  // declared unit library lives in — everything reachable that no unit
  // claims is core and public-by-design.
  final scanRoots = <String>{if (Directory('$root/lib').existsSync()) 'lib'};
  for (final lib in unitOfPath.keys) {
    final i = lib.indexOf('/lib/');
    if (i > 0) scanRoots.add(lib.substring(0, i + 4));
  }
  final allDart = <String>[];
  for (final scanRoot in scanRoots.toList()..sort()) {
    final dir = Directory('$root/$scanRoot');
    allDart.addAll(dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => _relative(root, f.path)));
  }
  allDart.sort();

  final libraries = <String, Map<String, String>>{};
  final fingerprints = <String, String>{};
  final coreLines = <String>[];
  for (final path in allDart) {
    final sha = sha256File('$root/$path');
    final unit = unitOf(path);
    if (unit == null) {
      coreLines.add('$path:$sha');
      continue;
    }
    (libraries[unit] ??= {})[path] = sha;
  }
  for (final unit in units) {
    final digests = libraries[unit.name];
    if (digests == null || digests.isEmpty) {
      throw ShipException(
          'unit `${unit.name}` claims no existing library (declared: '
          '${unit.libraries.join(', ')}) — fix the declaration');
    }
    final signatureLines = <String>[];
    for (final path in digests.keys) {
      signatureLines.addAll(_declarationLines('$root/$path'));
    }
    fingerprints[unit.name] = sha256Hex(signatureLines.join('\n').codeUnits);
  }

  return RevisionNode(
    revision: revision,
    parent: parent,
    baseline: baseline,
    plan: plan,
    coreFingerprint: sha256Hex(coreLines.join('\n').codeUnits),
    units: {for (final unit in units) unit.name: const RevisionUnit()},
    libraries: libraries,
    fingerprints: fingerprints,
    snapshot: snapshot,
  );
}

/// Lines that carry a declaration's shape: top-level, non-comment,
/// non-directive. A body edit inside an indented block leaves these
/// untouched; a single-expression top-level body change moves the
/// fingerprint (documented prototype behavior — fails closed).
List<String> _declarationLines(String path) {
  const skip = <String>[
    'import ', 'export ', 'part ', 'library', '//', '/*', '*', '@',
  ];
  return File(path)
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .where((line) => !line.startsWith(' ') && !line.startsWith('\t'))
      .where((line) => !skip.any(line.startsWith))
      .map((line) => line.trim())
      .toList();
}

/// The one-command ship (ADR-0035 Part 3's `oka ship` row, landed):
///
/// - fresh channel → publish a **baseline** node: the store build's
///   revision (never "current codebase"); a dirty tree refuses here,
///   because the baseline's digests are what every future diff is
///   measured against.
/// - existing channel → derive the next manifest from the tree, run
///   `planRevisions` against the head node's stored digests, compile one
///   delta per changed unit, write the node + artifacts, move the
///   pointer.
///
/// Refusals publish nothing. [dryRun] computes everything and writes
/// nothing. [compile] is required only when a patch is actually
/// possible.
Future<ShipReceipt> shipRevision({
  required String root,
  required List<PatchUnit> units,
  required String channelDir,
  required String revision,
  String? snapshotFile,
  SnapshotBuilder? snapshotBuilder,
  ChannelPolicy? policy,
  String channelName = 'stable',
  bool dryRun = false,
  UnitDeltaCompiler? compile,
  ChannelSigner? signer,
}) async {
  if (units.isEmpty) {
    throw ShipException(
        'no patch units declared — add tool/patch_units.dart exposing '
        '`UnitsSpec patchUnits` (ADR-0037 §1)');
  }
  final pointerFile = File('$channelDir/pointer.json');
  final pointer = pointerFile.existsSync()
      ? ChannelPointer.fromJson(decodeChannelJson(
          pointerFile.readAsBytesSync(), 'pointer.json'))
      : null;

  if (pointer == null) {
    return _shipBaseline(
        root: root,
        units: units,
        channelDir: channelDir,
        revision: revision,
        snapshotFile: snapshotFile,
        policy: policy,
        channelName: channelName,
        dryRun: dryRun,
        signer: signer);
  }

  final headFile = File('$channelDir/manifests/${pointer.revision}.json');
  if (!headFile.existsSync()) {
    throw ShipException(
        'pointer names revision ${pointer.revision} but its manifest is '
        'missing — the channel tree is corrupt');
  }
  final head = RevisionNode.fromJson(
      decodeChannelJson(headFile.readAsBytesSync(), pointer.revision));

  final next = deriveNode(
      revision: revision,
      parent: head.revision,
      baseline: head.baseline,
      root: root,
      units: units);
  final plan = planRevisions(_v1View(head), _v1View(next));

  if (!plan.patchable) {
    return ShipReceipt(
        ok: false,
        mode: 'refused',
        revision: revision,
        baseline: head.baseline,
        parentRevision: head.revision,
        plan: RecordedPlan(
            patchable: false,
            changedUnits: plan.changedUnits,
            coreChanged: plan.coreChanged,
            reasons: plan.reasons),
        reasons: [...plan.reasons, plan.alternative!]);
  }
  if (plan.changedUnits.isEmpty && !plan.coreChanged) {
    return ShipReceipt(
        ok: true,
        mode: 'nothing-to-ship',
        revision: revision,
        baseline: head.baseline,
        parentRevision: head.revision,
        plan: const RecordedPlan(
            patchable: true,
            changedUnits: [],
            coreChanged: false,
            reasons: []),
        reasons: ['no unit-body or core change against ${head.revision}']);
  }
  if (plan.changedUnits.isNotEmpty && compile == null) {
    return ShipReceipt(
        ok: false,
        mode: 'refused',
        revision: revision,
        baseline: head.baseline,
        parentRevision: head.revision,
        reasons: [
          'units ${plan.changedUnits.join(', ')} changed but no delta compiler is available (resolvePipelineToolchain + pipelineDeltaCompiler; ADR-0035 Part 1)'
        ]);
  }
  // One seam per revision (ADR-0035 §2e wire fact): a kernel delta
  // carries the entry library's recompiled set only, so a unit with
  // several changed files must ship as several revisions — like the
  // endless loop's continue/continue steps.
  for (final unitName in plan.changedUnits) {
    final changed = _changedFiles(head, next, unitName);
    if (changed.length > 1) {
      return ShipReceipt(
          ok: false,
          mode: 'refused',
          revision: revision,
          baseline: head.baseline,
          parentRevision: head.revision,
          reasons: [
            'unit `$unitName` has ${changed.length} changed files (${changed.join(', ')}) but a delta carries one seam per revision — ship them one revision at a time'
          ]);
    }
  }

  // Per-unit changed files from the digest diff — the "patch generated
  // from the code and the previous diffs" step.
  final deltas = <ShipDelta>[];
  for (final unitName in plan.changedUnits) {
    final changed = _changedFiles(head, next, unitName);
    if (changed.isEmpty) continue;
    final artifact = await compile!(DeltaRequest(
        revision: revision,
        unit: unitName,
        root: root,
        patchedFiles: changed));
    final file = 'artifacts/$unitName-$revision.delta.dill';
    final target = '$channelDir/$file';
    if (!dryRun) {
      Directory('$channelDir/artifacts').createSync(recursive: true);
      File(artifact.path).copySync(target);
    }
    deltas.add(ShipDelta(
        unit: unitName,
        revision: revision,
        artifact: UnitArtifact(
            file: file,
            sha256: sha256File(artifact.path),
            bytes: artifact.bytes),
        changedFiles: changed));
  }

  // Snapshot lane (G-AC6): derive the whole-revision snapshot from the
  // build pipeline when the chain a fresh client would apply would overrun
  // the effective policy (the pointer's, or this ship's explicit override)
  // — shipping an unusable chain is worse than shipping bytes. An explicit
  // `snapshotFile` always wins.
  final newBytes =
      deltas.fold<int>(0, (sum, d) => sum + d.artifact.bytes);
  final load = chainLoad(channelDir, head, head.baseline);
  final chainBytes = load.bytes + newBytes;
  final chainRevisions = load.revisions + 1;
  final effectivePolicy = policy ?? pointer.policy;
  final overPolicy = chainBytes > effectivePolicy.maxChainBytes ||
      chainRevisions > effectivePolicy.maxChainRevisions;
  var snapshotReason = <String>[];
  UnitArtifact? snapshot;
  if (snapshotFile != null) {
    snapshot = _stageSnapshot(channelDir, revision, snapshotFile,
        dryRun: dryRun);
  } else if (snapshotBuilder != null && overPolicy) {
    final built = File(await snapshotBuilder());
    snapshot = _stageSnapshot(channelDir, revision, built.path,
        dryRun: dryRun);
    final why = 'snapshot derived from the build pipeline: chain to head '
        'would be $chainBytes B / $chainRevisions revisions against policy '
        '(maxChainBytes ${effectivePolicy.maxChainBytes}, '
        'maxChainRevisions ${effectivePolicy.maxChainRevisions})';
    snapshotReason = [why];
  }

  if (dryRun) {
    return ShipReceipt(
        ok: true,
        mode: 'dry-run',
        revision: revision,
        baseline: head.baseline,
        parentRevision: head.revision,
        plan: RecordedPlan(
            patchable: true,
            changedUnits: plan.changedUnits,
            coreChanged: plan.coreChanged,
            reasons: plan.reasons),
        deltas: deltas,
        snapshot: snapshot,
        reasons: snapshotReason,
        dirtyTree: _treeDirty(root));
  }

  await _writeNode(channelDir, RevisionNode(
      revision: revision,
      parent: head.revision,
      baseline: head.baseline,
      plan: RecordedPlan(
          patchable: true,
          changedUnits: plan.changedUnits,
          coreChanged: plan.coreChanged,
          reasons: plan.reasons),
      coreFingerprint: next.coreFingerprint,
      units: {
        for (final unit in units)
          unit.name: RevisionUnit(
              delta: deltas
                  .where((d) => d.unit == unit.name)
                  .map((d) => d.artifact)
                  .firstOrNull),
      },
      libraries: next.libraries,
      fingerprints: next.fingerprints,
      snapshot: snapshot), signer);
  await _writePointer(
      channelDir,
      ChannelPointer(
          channel: pointer.channel,
          revision: revision,
          // An explicit publisher override re-seeds the pointer policy
          // (tightening/loosening thresholds is a publisher action);
          // otherwise the channel's policy is preserved.
          policy: policy ?? pointer.policy,
          signedBy: pointer.signedBy),
      signer);

  return ShipReceipt(
      ok: true,
      mode: 'patch',
      revision: revision,
      baseline: head.baseline,
      parentRevision: head.revision,
      plan: RecordedPlan(
          patchable: true,
          changedUnits: plan.changedUnits,
          coreChanged: plan.coreChanged,
          reasons: plan.reasons),
      deltas: deltas,
      snapshot: snapshot,
      reasons: snapshotReason,
      dirtyTree: _treeDirty(root));
}

Future<ShipReceipt> _shipBaseline({
  required String root,
  required List<PatchUnit> units,
  required String channelDir,
  required String revision,
  required String? snapshotFile,
  required ChannelPolicy? policy,
  required String channelName,
  required bool dryRun,
  required ChannelSigner? signer,
}) async {
  final dirty = _treeDirty(root);
  if (dryRun) {
    return ShipReceipt(
        ok: true,
        mode: 'dry-run',
        revision: revision,
        baseline: revision,
        reasons: [
          'would seed channel baseline at $revision (no deltas; future ships diff against it)'
        ],
        dirtyTree: dirty);
  }
  if (dirty) {
    return ShipReceipt(
        ok: false,
        mode: 'refused',
        revision: revision,
        baseline: revision,
        reasons: [
          'working tree is dirty — a baseline must be exactly the store build; commit or stash first'
        ],
        dirtyTree: true);
  }
  final snapshot = _stageSnapshot(channelDir, revision, snapshotFile);
  final node = deriveNode(
      revision: revision,
      parent: null,
      baseline: revision,
      root: root,
      units: units,
      snapshot: snapshot);
  await _writeNode(channelDir, node, signer);
  await _writePointer(
      channelDir,
      ChannelPointer(
          channel: channelName,
          revision: revision,
          policy: policy ?? const ChannelPolicy()),
      signer);
  return ShipReceipt(
      ok: true,
      mode: 'baseline',
      revision: revision,
      baseline: revision,
      snapshot: snapshot);
}

// --- writers ----------------------------------------------------------------

const _json = JsonEncoder.withIndent('  ');

Future<void> _writeNode(
    String channelDir, RevisionNode node, ChannelSigner? signer) async {
  Directory('$channelDir/manifests').createSync(recursive: true);
  Directory('$channelDir/artifacts').createSync(recursive: true);
  final json = signer == null ? node.toJson() : await signer.sign(node.toJson());
  File('$channelDir/manifests/${node.revision}.json')
      .writeAsStringSync('${_json.convert(json)}\n');
}

Future<void> _writePointer(
    String channelDir, ChannelPointer pointer, ChannelSigner? signer) async {
  Directory(channelDir).createSync(recursive: true);
  final json =
      signer == null ? pointer.toJson() : await signer.sign(pointer.toJson());
  File('$channelDir/pointer.json')
      .writeAsStringSync('${_json.convert(json)}\n');
}

UnitArtifact? _stageSnapshot(
    String channelDir, String revision, String? snapshotFile,
    {bool dryRun = false}) {
  if (snapshotFile == null) return null;
  final source = File(snapshotFile);
  if (!source.existsSync()) {
    throw ShipException('snapshot file missing: $snapshotFile');
  }
  // Keep the source's extension: a kernel dill snapshot and a web bundle
  // tar are different shapes and the artifact name should say which.
  final ext = source.path.contains('.')
      ? source.path.substring(source.path.lastIndexOf('.'))
      : '';
  final file = 'artifacts/$revision.snapshot$ext';
  if (!dryRun) {
    Directory('$channelDir/artifacts').createSync(recursive: true);
    source.copySync('$channelDir/$file');
  }
  return UnitArtifact(
      file: file,
      sha256: sha256File(source.path),
      bytes: source.lengthSync());
}

// --- helpers ----------------------------------------------------------------

/// The v1 manifest view `planRevisions` consumes, built from a node's
/// persisted digests.
Map<String, dynamic> _v1View(RevisionNode node) => {
      'schemaVersion': 1,
      'revision': node.revision,
      'coreFingerprint': node.coreFingerprint,
      'units': {
        for (final unit in node.libraries.keys)
          unit: {
            'libraries': {
              for (final e in node.libraries[unit]!.entries)
                e.key: {'sha256': e.value},
            },
            'contractFingerprint': node.fingerprints[unit],
          },
      },
    };

List<String> _changedFiles(RevisionNode base, RevisionNode next,
    String unit) {
  final before = base.libraries[unit] ?? const {};
  final after = next.libraries[unit] ?? const {};
  return [
    for (final e in after.entries)
      if (before[e.key] != e.value) e.key,
  ];
}

/// Git dirty check; a non-git root counts as clean (the check is only
/// meaningful inside a checkout — the receipt stamps the source of truth).
bool _treeDirty(String root) {
  final result = Process.runSync('git', ['status', '--porcelain'],
      workingDirectory: root);
  if (result.exitCode != 0) return false;
  return (result.stdout as String).trim().isNotEmpty;
}

String _relative(String root, String path) =>
    path.substring(root.length + 1).replaceAll(r'\', '/');
