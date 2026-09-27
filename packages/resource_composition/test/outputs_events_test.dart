import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  test('ResolvedOutputs enforces presence and type', () {
    const port = OutputRef<int>('collector.port');
    const outputs = ResolvedOutputs({'collector.port': 8081});
    expect(outputs.require(port), 8081);
    expect(outputs.contains(port), isTrue);

    const missing = ResolvedOutputs.empty;
    expect(
      () => missing.require(port),
      throwsA(
        isA<StateError>().having(
          (final e) => e.message,
          'message',
          contains('violated its declared provides'),
        ),
      ),
    );

    const wrongType = ResolvedOutputs({'collector.port': '8081'});
    expect(
      () => wrongType.require(port),
      throwsA(
        isA<StateError>().having(
          (final e) => e.message,
          'message',
          contains('expected int'),
        ),
      ),
    );
  });

  test('scopedTo hands a dependent exactly its declared requirements', () {
    const port = OutputRef<int>('collector.port');
    const extra = OutputRef<String>('other.thing');
    const outputs = ResolvedOutputs({
      'collector.port': 8081,
      'other.thing': 'x',
    });
    final scoped = outputs.scopedTo([port]);
    expect(scoped.require(port), 8081);
    expect(scoped.contains(extra), isFalse);
  });

  test('lifecycle events serialize to stable JSONL lines', () {
    final at = DateTime.utc(2026, 9, 27, 12);
    final ready = ComponentReady(
      componentId: 'collector',
      at: at,
      outputs: {'collector.port': 8081},
    );
    expect(
      ready.toJsonLine(),
      '{"kind":"componentReady","component":"collector",'
      '"at":"2026-09-27T12:00:00.000Z","outputs":{"collector.port":8081}}',
    );

    final stopped = ComponentStopped(
      componentId: 'collector',
      at: at,
      cause: TerminalCause.killedOnDeadline,
    );
    expect(
      stopped.toJsonLine(),
      '{"kind":"componentStopped","component":"collector",'
      '"at":"2026-09-27T12:00:00.000Z","cause":"killedOnDeadline"}',
    );

    final timeout = ReadinessTimeout(
      componentId: 'agent',
      at: at,
      budget: const Duration(milliseconds: 250),
    );
    expect(
      timeout.toJsonLine(),
      contains('"kind":"readinessTimeout"'),
    );
    expect(timeout.toJsonLine(), contains('"budgetMs":250'));
  });

  test('terminal causes cover the survey failure classes', () {
    // F5: death has a meaning — the enum must carry provider faults and
    // transport loss distinctly from deadline kills.
    expect(TerminalCause.values.map((final c) => c.name), containsAll([
      'exited',
      'signaled',
      'killedOnDeadline',
      'providerFault',
      'transportLost',
      'unknown',
    ]));
  });
}
