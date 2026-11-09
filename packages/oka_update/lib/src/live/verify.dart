import 'events.dart';
import 'probe_match.dart';
import 'receipt.dart';
import 'session.dart';
import 'spec.dart';
import 'target.dart';

/// The `verify` verb: connect to every target, capture the probes, and
/// close — no patch, no eligibility ceremony. A receipt whose targets are
/// `ok` means the targets are reachable and the probes evaluate; probe
/// values travel in [ProbeResult.before] (with `after` mirroring it).
///
/// This is the pre-flight half of [LivePatchSession.run]: use it to check
/// a composition's targets before touching anything, or as the
/// agent-facing `oka.live.verify` action (ADR-0036 Tier 2).
Future<LivePatchReceipt> verifyLiveTargets(
  LivePatchSpec spec, {
  required String root,
  Map<String, LivePatchTarget> targetOverrides = const {},
  void Function(LivePatchEvent event)? onEvent,
}) async {
  final session = LivePatchSession(
    spec: LivePatchSpec(
      revision: spec.revision,
      unit: spec.unit,
      patches: const [],
      targets: spec.targets,
      probes: spec.probes,
    ),
    root: root,
    compile: (request) =>
        throw UnsupportedError('verify never compiles a delta'),
    targetOverrides: targetOverrides,
    onEvent: onEvent,
  );
  final (:baselines, :connectErrors) = await session.verifyOnly();
  // Release every wire: verify is a read-only pass — the sockets must
  // not keep the process alive after the receipt prints.
  for (final t in session.targets.values) {
    if (connectErrors.containsKey(t.id)) continue;
    try {
      await t.close();
    } on Object {
      // Best-effort: the receipt is already complete.
    }
  }
  final targets = <TargetReceipt>[];
  var ok = true;
  for (final t in spec.targets) {
    final errors = connectErrors[t.id];
    final values = baselines[t.id] ?? const <String, String>{};
    if (errors != null) ok = false;
    final probeResults = <ProbeResult>[];
    for (final p in spec.probes) {
      final captured = values[probeKey(p)];
      String observed;
      String? probeError;
      if (errors != null) {
        observed = errors;
        probeError = errors;
      } else if (captured == null) {
        observed = 'not captured';
        probeError = 'probe not captured';
      } else {
        observed = captured;
      }
      var probeOk = errors == null && captured != null;
      if (probeOk) {
        probeOk = probeResultSatisfiesSpec(
          observed: observed,
          expect: p.expect,
          hold: p.hold,
          before: observed,
        );
        if (!probeOk && p.expect != null) {
          probeError = 'expected `${p.expect}`, observed `$observed`';
        } else if (!probeOk && p.hold) {
          probeError = 'hold violated';
        }
      }
      if (!probeOk) ok = false;
      probeResults.add(
        ProbeResult(
          probe: p.expression,
          before: observed,
          after: observed,
          ok: probeOk,
          held: p.hold,
          error: probeError,
        ),
      );
    }
    targets.add(TargetReceipt(
      targetId: t.id,
      kind: t.kind,
      ok: errors == null && probeResults.every((r) => r.ok),
      mode: errors == null ? 'verify' : 'unreachable',
      probes: probeResults,
      refusal: errors,
    ));
  }
  return LivePatchReceipt(
    revision: spec.revision,
    unit: spec.unit,
    ok: ok,
    targets: targets,
  );
}
