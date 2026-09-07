import 'package:oka_core/oka_core.dart';

/// Thrown by [expectPlanShape] when a dry-run plan does not describe
/// exactly what a real run would do.
class PlanShapeException implements Exception {
  PlanShapeException({required this.plan, required this.mismatches});

  /// The offending plan (renderable with [PublishPlan.describeLines]).
  final PublishPlan plan;

  /// Human-readable mismatches — one entry per failed expectation.
  final List<String> mismatches;

  @override
  String toString() =>
      'publish plan does not have the expected shape:\n'
      '${mismatches.map((final m) => '  - $m').join('\n')}\n'
      'plan: ${plan.describeLines().join('\n  ')}';
}

/// Asserts the shape of a dry-run [PublishPlan] (ADR-0014 law 1): the plan
/// must name the endpoint, track, artifact id/path, and every piece of
/// non-secret metadata a real run would use — no more, no less.
///
/// [metadata] is matched as a subset (the plan may carry more entries);
/// pass [exactMetadata] as `true` to require an exact map. [credentials]
/// must match the plan's refs exactly (order included).
void expectPlanShape(
  final PublishPlan plan, {
  final String? target,
  final String? endpoint,
  final String? track,
  final String? artifactId,
  final String? artifactPath,
  final bool? dryRun,
  final Map<String, String> metadata = const {},
  final bool exactMetadata = false,

  /// Pass a non-empty list to assert the plan's credential refs exactly;
  /// null (the default) skips the credentials check.
  final List<CredentialRef>? credentials,
}) {
  final m = <String>[];
  void check(final String what, final Object? expected, final Object? actual) {
    if (expected != null && expected != actual) {
      m.add('$what: expected $expected, plan says $actual');
    }
  }

  check('target', target, plan.target);
  check('endpoint', endpoint, plan.endpoint);
  check('track', track, plan.track);
  check('artifactId', artifactId, plan.artifactId);
  check('artifactPath', artifactPath, plan.artifactPath);
  check('dryRun', dryRun, plan.dryRun);

  for (final entry in metadata.entries) {
    if (!plan.metadata.containsKey(entry.key)) {
      m.add('metadata is missing "${entry.key}" '
          '(plan has: ${plan.metadata.keys.join(', ')})');
    } else if (plan.metadata[entry.key] != entry.value) {
      m.add('metadata.${entry.key}: expected "${entry.value}", plan says '
          '"${plan.metadata[entry.key]}"');
    }
  }
  if (exactMetadata) {
    for (final key in plan.metadata.keys) {
      if (!metadata.containsKey(key)) {
        m.add('metadata has unexpected key "$key"');
      }
    }
  }

  final expectedCredentials = credentials;
  if (expectedCredentials != null) {
    for (var i = 0; i < expectedCredentials.length; i++) {
      if (i >= plan.credentials.length) {
        m.add('credentials: expected ${expectedCredentials.length} refs, '
            'plan has ${plan.credentials.length}');
        break;
      }
      if (plan.credentials[i] != expectedCredentials[i]) {
        m.add('credentials[$i]: expected ${expectedCredentials[i]} — '
            'plan says ${plan.credentials[i]}');
      }
    }
    if (expectedCredentials.length < plan.credentials.length) {
      m.add('credentials: plan carries ${plan.credentials.length} refs, '
          'expected ${expectedCredentials.length}');
    }
  }

  if (m.isNotEmpty) throw PlanShapeException(plan: plan, mismatches: m);
}

/// Asserts the plan renders as *describable text* (the agent-facing law):
/// every listed fragment must appear in `plan.describeLines()`.
void expectPlanDescribes(final PublishPlan plan, final List<String> fragments) {
  final joined = plan.describeLines().join('\n');
  final missing = fragments.where((final f) => !joined.contains(f)).toList();
  if (missing.isNotEmpty) {
    throw PlanShapeException(
      plan: plan,
      mismatches: [
        for (final f in missing) 'describeLines() does not mention "$f"',
      ],
    );
  }
}
