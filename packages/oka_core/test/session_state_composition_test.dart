import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

final class _Handle {}

final class _Planner implements SessionStatePlanner<_Handle> {
  const _Planner();

  @override
  String get id => 'composition-test-planner';

  @override
  SessionStatePlan<_Handle> plan(final SessionStateRequest request) =>
      throw UnimplementedError();
}

final class _Source implements SessionStateSource<_Handle> {
  const _Source();

  @override
  String get id => 'composition-test-source';

  @override
  Future<_Handle> restore(final SessionStateLease lease) =>
      throw UnimplementedError();
}

final class _ContributingTarget extends Target
    implements SessionStateWorkflowContributor {
  const _ContributingTarget(this.workflows);

  final List<SessionStateWorkflow<dynamic>> workflows;

  @override
  Iterable<SessionStateWorkflow<dynamic>> get sessionStateWorkflows =>
      workflows;

  @override
  String get name => 'workflow-target';

  @override
  String get description => 'Contributes test workflows';

  @override
  List<BuildStep> compile(final BuildContext ctx) => const [];
}

final class _PlainTarget extends Target {
  const _PlainTarget();

  @override
  String get name => 'plain-target';

  @override
  String get description => 'Does not contribute workflows';

  @override
  List<BuildStep> compile(final BuildContext ctx) => const [];
}

SessionStateWorkflow<_Handle> _workflow({
  final String id = 'composition-test',
  final int version = 1,
}) => SessionStateWorkflow(
  id: id,
  version: version,
  plan: const _Planner(),
  source: const _Source(),
);

void main() {
  group('Oka effective session-state workflows', () {
    test('gathers contributed workflows after explicit workflows', () {
      final explicit = _workflow(id: 'explicit');
      final contributed = _workflow(id: 'contributed');
      final oka = Oka(
        pipelines: const [],
        sessionStateWorkflows: [explicit],
        targets: [
          _ContributingTarget([contributed]),
          const _PlainTarget(),
        ],
      );

      expect(oka.effectiveSessionStateWorkflows, [explicit, contributed]);
    });

    test(
      'deduplicates only the identical explicit and contributed instance',
      () {
        final shared = _workflow();
        final distinctConflict = _workflow();
        final oka = Oka(
          pipelines: const [],
          sessionStateWorkflows: [shared],
          targets: [
            _ContributingTarget([shared, distinctConflict]),
          ],
        );

        final effective = oka.effectiveSessionStateWorkflows;
        expect(effective, hasLength(2));
        expect(effective[0], same(shared));
        expect(effective[1], same(distinctConflict));
      },
    );
  });
}
