import 'events.dart';
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
  final targets = <TargetReceipt>[];
  var ok = true;
  for (final t in spec.targets) {
    final errors = connectErrors[t.id];
    final values = baselines[t.id] ?? const <String, String>{};
    if (errors != null) ok = false;
    targets.add(TargetReceipt(
      targetId: t.id,
      kind: t.kind,
      ok: errors == null,
      mode: errors == null ? 'verify' : 'unreachable',
      probes: [
        for (final p in spec.probes)
          ProbeResult(
            probe: p.expression,
            before: values[probeKey(p)] ?? (errors ?? 'not captured'),
            after: values[probeKey(p)] ?? (errors ?? 'not captured'),
            ok: errors == null && values.containsKey(probeKey(p)),
            held: true,
          ),
      ],
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
