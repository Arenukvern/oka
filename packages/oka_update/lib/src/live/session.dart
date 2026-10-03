/// The composable driver: one session takes a declarative spec, an
/// injected delta compiler, and any set of targets, and turns a patch into
/// receipts — streaming every step as events. Easy to use (one call), easy
/// to debug (the event ladder + `describe()`), composable (targets and the
/// compiler are interfaces), declarative (the spec is data).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../patch_plan.dart';
import 'events.dart';
import 'receipt.dart';
import 'spec.dart';
import 'staged_target.dart';
import 'target.dart';
import 'vm_target.dart';
import 'web_target.dart';

/// Produces the unit delta consumed by (native) targets. Injected so the
/// session has no compile-time dependency on the kernel pipeline: oka's
/// gate pipeline (`gate_pipeline.dart --delta`) is one implementation; the
/// frontend_server is another; a no-op is valid for web-only runs.
typedef UnitDeltaCompiler = Future<DeltaArtifact> Function(
    DeltaRequest request);

class DeltaRequest {
  const DeltaRequest({
    required this.revision,
    required this.unit,
    required this.root,
    required this.patchedFiles,
  });

  final String revision;
  final String unit;

  /// App root the spec's relative paths resolve against.
  final String root;
  final List<String> patchedFiles;
}

class DeltaArtifact {
  const DeltaArtifact({required this.path, required this.bytes});
  final String path;
  final int bytes;
}

/// Builds a target from its spec entry. Overridable per-session for custom
/// targets.
typedef TargetFactory = LivePatchTarget Function(TargetSpec spec);

LivePatchTarget targetFromSpec(TargetSpec spec) {
  switch (spec.kind) {
    case 'vm':
      return VmJitTarget(
        id: spec.id,
        wsUri: spec.ws!,
        httpEndpoint: spec.http,
        devfsName: spec.devfs,
        applyVia: spec.applyVia,
        packagesPath: spec.packages,
      );
    case 'web':
      return WebDwdsTarget(
        id: spec.id,
        wsUri: spec.ws!,
        pidFile: spec.pidFile,
        signal: spec.signal,
        cdpPageWsUrl: spec.cdp,
      );
    case 'staged':
      return StagedTarget(
        id: spec.id,
        artifactsDir: spec.dir!,
        baseArtifact: spec.base!,
        unitArtifact: spec.unitArtifact!,
      );
    default:
      throw ArgumentError('unknown target kind: ${spec.kind}');
  }
}

class LivePatchSession {
  LivePatchSession({
    required this.spec,
    required this.compile,
    required this.root,
    this.targetOverrides = const <String, LivePatchTarget>{},
    this.onEvent,
  })  : targets = {
          for (final t in spec.targets)
            t.id: targetOverrides[t.id] ?? targetFromSpec(t),
        };

  final LivePatchSpec spec;
  final UnitDeltaCompiler compile;
  final String root;
  final Map<String, LivePatchTarget> targetOverrides;

  /// Target id -> target, resolved from the spec (+ overrides) at
  /// construction.
  final Map<String, LivePatchTarget> targets;
  final void Function(LivePatchEvent event)? onEvent;

  final _events = StreamController<LivePatchEvent>.broadcast();
  Stream<LivePatchEvent> get events => _events.stream;

  void _emit(LivePatchEvent e) {
    _events.add(e);
    onEvent?.call(e);
  }

  /// Applies the patch across every target and returns the receipt. Never
  /// throws for expected failures — they are in the receipt.
  Future<LivePatchReceipt> run() async {
    // 1. Eligibility (optional manifests, ADR-0031 §3).
    if (spec.baseManifest != null && spec.nextManifest != null) {
      final base = (jsonDecode(
              await File(spec.baseManifest!).readAsString()) as Map)
          .cast<String, dynamic>();
      final next = (jsonDecode(
              await File(spec.nextManifest!).readAsString()) as Map)
          .cast<String, dynamic>();
      final plan = planRevisions(base, next);
      _emit(LivePatchEvent(
        phase: LivePatchPhase.planned,
        unit: spec.unit,
        details: {
          'patchable': plan.patchable,
          'reasons': plan.reasons,
          'changedUnits': plan.changedUnits,
        },
      ));
      if (!plan.patchable) {
        return _refuse('eligibility refused: ${plan.reasons.join('; ')}');
      }
    } else {
      _emit(LivePatchEvent(
          phase: LivePatchPhase.planned,
          unit: spec.unit,
          details: {'patchable': true, 'reasons': <String>[]}));
    }

    // 2. Connect every target; capture baseline probe values BEFORE any
    //    file changes.
    final (:baselines, :connectErrors) = await _connectAndBaseline();

    // 3. Patch the sources on disk.
    final patchedFiles = <String>[];
    for (final edit in spec.patches) {
      final path = edit.file.startsWith('/') ? edit.file : '$root/${edit.file}';
      final current = await File(path).readAsString();
      final next = current.replaceFirst(edit.find, edit.replace);
      if (next == current) {
        return _refuse('patch marker not found in ${edit.file}',
            connectErrors: connectErrors);
      }
      await File(path).writeAsString(next);
      patchedFiles.add(path);
    }
    _emit(LivePatchEvent(
        phase: LivePatchPhase.patched,
        unit: spec.unit,
        details: {'files': patchedFiles.length}));

    // 4. Compile the unit delta (injected compiler).
    late final DeltaArtifact delta;
    try {
      delta = await compile(DeltaRequest(
          revision: spec.revision,
          unit: spec.unit,
          root: root,
          patchedFiles: patchedFiles));
    } catch (e) {
      return _refuse('delta compile failed: $e',
          connectErrors: connectErrors);
    }
    _emit(LivePatchEvent(
        phase: LivePatchPhase.compiled,
        unit: spec.unit,
        details: {'bytes': delta.bytes, 'path': delta.path}));

    final receipts =
        await _applyAndVerify(delta: delta, baselines: baselines, connectErrors: connectErrors);
    final ok = receipts.every((t) => t.ok) &&
        receipts.expand((t) => t.probes).every((p) => p.ok);
    await _events.close();
    return LivePatchReceipt(
      revision: spec.revision,
      unit: spec.unit,
      ok: ok,
      targets: receipts,
    );
  }

  /// Connects every target and captures baseline probe values. A target
  /// that cannot connect is recorded as a connect error, not a crash — the
  /// rest still runs.
  Future<
      ({
        Map<String, Map<String, String>> baselines,
        Map<String, String> connectErrors
      })> _connectAndBaseline() async {
    final baselines = <String, Map<String, String>>{};
    final connectErrors = <String, String>{};
    for (final entry in targets.entries) {
      try {
        await entry.value.connect();
        final base = <String, String>{};
        for (final p in spec.probes) {
          base[_probeKey(p)] = await entry.value.evaluate(p);
        }
        baselines[entry.key] = base;
        _emit(LivePatchEvent(
          phase: LivePatchPhase.connected,
          targetId: entry.key,
          unit: spec.unit,
          details: {'probes': spec.probes.length},
        ));
      } catch (e) {
        connectErrors[entry.key] = e.toString();
        _emit(LivePatchEvent(
          phase: LivePatchPhase.failed,
          targetId: entry.key,
          unit: spec.unit,
          details: {'error': 'connect failed: $e'},
        ));
      }
    }
    return (baselines: baselines, connectErrors: connectErrors);
  }

  /// The verify verb's engine: connect + capture probes, then close —
  /// no patch, no compile. Returns the same record [run] starts from.
  Future<
      ({
        Map<String, Map<String, String>> baselines,
        Map<String, String> connectErrors
      })> verifyOnly() async {
    final r = await _connectAndBaseline();
    await _closeEvents();
    return r;
  }

  /// Applies [delta] to every connected target, verifies probes (with
  /// settle polling), and builds per-target receipts.
  Future<List<TargetReceipt>> _applyAndVerify({
    required DeltaArtifact delta,
    required Map<String, Map<String, String>> baselines,
    required Map<String, String> connectErrors,
  }) async {
    final probeResults = <String, List<ProbeResult>>{};
    final applyModes = <String, ApplyOutcome>{};
    for (final entry in targets.entries) {
      final id = entry.key;
      if (connectErrors.containsKey(id)) {
        probeResults[id] = const [];
        continue;
      }
      _emit(LivePatchEvent(
          phase: LivePatchPhase.applying,
          targetId: id,
          unit: spec.unit,
          details: {'mode': 'wire'}));
      final sw = Stopwatch()..start();
      final outcome = await entry.value.apply(
          unit: spec.unit, deltaPath: delta.path, deltaBytes: delta.bytes);
      sw.stop();
      final settleMs = spec.targets
          .firstWhere((t) => t.id == id,
              orElse: () => TargetSpec(kind: 'vm', id: id))
          .settleMs;
      if (outcome.ok && settleMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: settleMs));
      }
      applyModes[id] = outcome;
      _emit(LivePatchEvent(
        phase: outcome.ok ? LivePatchPhase.applied : LivePatchPhase.failed,
        targetId: id,
        unit: spec.unit,
        details: {
          'mode': outcome.mode,
          'durationMs': sw.elapsedMilliseconds,
          if (!outcome.ok) 'error': outcome.error,
          ...outcome.wire,
        },
      ));

      // 6. Verify probes on this target. With settleMs set, expect-probes
      // POLL until they flip or the budget ends — wires whose apply
      // returns before the program has recompiled/reloaded need this.
      final settleBudget = spec.targets
          .firstWhere((t) => t.id == id,
              orElse: () => TargetSpec(kind: 'vm', id: id))
          .settleMs;
      final results = <ProbeResult>[];
      for (final p in spec.probes) {
        final key = _probeKey(p);
        final before = baselines[id]![key]!;
        String after;
        var error = outcome.ok ? null : 'apply failed: ${outcome.error}';
        if (outcome.ok) {
          try {
            after = await entry.value.evaluate(p);
            if (p.expect != null && !after.contains(p.expect!)) {
              final deadline = DateTime.now().add(
                  Duration(milliseconds: settleBudget));
              while (DateTime.now().isBefore(deadline)) {
                await Future<void>.delayed(const Duration(seconds: 2));
                after = await entry.value.evaluate(p);
                if (after.contains(p.expect!)) break;
              }
            }
          } catch (e) {
            after = before;
            error = 'evaluate failed: $e';
          }
        } else {
          after = before;
        }
        var ok = error == null;
        var held = false;
        if (ok && p.hold) {
          held = after == before;
          ok = held;
        } else if (ok && p.expect != null) {
          ok = after.contains(p.expect!);
        }
        results.add(ProbeResult(
            probe: p.expression,
            before: before,
            after: after,
            ok: ok,
            held: held,
            error: error));
        _emit(LivePatchEvent(
          phase: LivePatchPhase.verified,
          targetId: id,
          unit: spec.unit,
          details: {
            'probe': p.expression,
            'before': before,
            'after': after,
            'held': held,
            if (!ok) 'error': error,
          },
        ));
      }
      probeResults[id] = results;
    }

    // 7. Receipt.
    final receipts = <TargetReceipt>[];
    for (final entry in targets.entries) {
      final id = entry.key;
      final outcome = applyModes[id];
      final connectError = connectErrors[id];
      receipts.add(TargetReceipt(
        targetId: id,
        kind: entry.value.kind,
        ok: connectError == null && (outcome?.ok ?? false),
        mode: outcome?.mode ??
            (connectError != null ? 'unreachable' : 'not-applied'),
        deltaBytes: outcome == null ? null : delta.bytes,
        probes: probeResults[id] ?? const [],
        refusal: connectError ??
            (outcome == null ? null : (outcome.ok ? null : outcome.error)),
      ));
    }
    return receipts;
  }

  /// Reverts the source edits (replace -> find). For drivers' finally
  /// blocks and tests.
  Future<void> restore() async {
    for (final edit in spec.patches.reversed) {
      final path = edit.file.startsWith('/') ? edit.file : '$root/${edit.file}';
      final current = await File(path).readAsString();
      await File(path)
          .writeAsString(current.replaceFirst(edit.replace, edit.find));
    }
  }

  Future<void> _closeEvents() async {
    if (!_events.isClosed) await _events.close();
  }

  LivePatchReceipt _refuse(
    String reason, {
    Map<String, String> connectErrors = const {},
  }) {
    _emit(LivePatchEvent(
        phase: LivePatchPhase.refused,
        unit: spec.unit,
        details: {'reason': reason}));
    unawaited(_closeEvents());
    return LivePatchReceipt(
      revision: spec.revision,
      unit: spec.unit,
      ok: false,
      targets: [
        for (final t in targets.entries)
          TargetReceipt(
            targetId: t.key,
            kind: t.value.kind,
            ok: false,
            mode: 'unreachable',
            refusal: connectErrors[t.key] ?? reason,
          ),
      ],
      refusal: reason,
    );
  }

  String _probeKey(ProbeSpec p) => probeKey(p);
}

/// The key a [ProbeSpec] travels under in baselines and receipts.
String probeKey(ProbeSpec p) => '${p.library ?? ''}#${p.expression}';


/// One-call live patch: the composition root's entry point. Wraps
/// [LivePatchSession] with the conventional defaults — patch file paths
/// resolve against [root], every step streams to [onEvent], and the receipt
/// is returned for programmatic checks (or printed via `describe()`).
///
/// ```dart
/// final receipt = await runLivePatch(
///   myPatch,                       // the composed LivePatchSpec value
///   root: appRoot,
///   compile: pipelineDeltaCompiler(toolchain), // from oka_dart_kernel
///   onEvent: (e) => print(e.why),
/// );
/// if (!receipt.ok) print(receipt.describe());
/// ```
Future<LivePatchReceipt> runLivePatch(
  LivePatchSpec spec, {
  required UnitDeltaCompiler compile,
  required String root,
  Map<String, LivePatchTarget> targetOverrides = const {},
  void Function(LivePatchEvent event)? onEvent,
}) {
  final session = LivePatchSession(
    spec: spec,
    root: root,
    compile: compile,
    targetOverrides: targetOverrides,
    onEvent: onEvent,
  );
  return session.run();
}

/// The invisible loop (ADR-0035): the user already edited [changedFile] in
/// their editor — compile that file's library as the unit delta and apply
/// it to every connected target. No file rewriting, no eligibility
/// ceremony: the same apply + probe verification as [run], driven by a
/// file watcher instead of a command.
///
/// Refusals and probe failures land in the receipt, exactly like [run];
/// successes are silent unless [onEvent] listens.
Future<LivePatchReceipt> applyChange(
  LivePatchSpec spec, {
  required String changedFile,
  required UnitDeltaCompiler compile,
  required String root,
  Map<String, LivePatchTarget> targetOverrides = const {},
  void Function(LivePatchEvent event)? onEvent,
}) async {
  final patchedSpec = LivePatchSpec(
    revision: spec.revision,
    unit: spec.unit,
    patches: const [],
    targets: spec.targets,
    probes: spec.probes,
  );
  final session = LivePatchSession(
    spec: patchedSpec,
    root: root,
    compile: compile,
    targetOverrides: targetOverrides,
    onEvent: onEvent,
  );
  final (:baselines, :connectErrors) = await session._connectAndBaseline();

  late final DeltaArtifact delta;
  try {
    delta = await compile(DeltaRequest(
        revision: spec.revision,
        unit: spec.unit,
        root: root,
        patchedFiles: [changedFile]));
  } catch (e) {
    await session._events.close();
    return LivePatchReceipt(
      revision: spec.revision,
      unit: spec.unit,
      ok: false,
      targets: const [],
      refusal: 'delta compile failed: $e',
    );
  }
  session._emit(LivePatchEvent(
      phase: LivePatchPhase.compiled,
      unit: spec.unit,
      details: {'bytes': delta.bytes, 'path': delta.path}));

  final receipts = await session._applyAndVerify(
      delta: delta, baselines: baselines, connectErrors: connectErrors);
  final ok = receipts.every((t) => t.ok) &&
      receipts.expand((t) => t.probes).every((p) => p.ok);
  await session._events.close();
  return LivePatchReceipt(
    revision: spec.revision,
    unit: spec.unit,
    ok: ok,
    targets: receipts,
  );
}
