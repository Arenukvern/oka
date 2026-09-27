import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  test('starts in topological order and injects dependency outputs', () async {
    const port = OutputRef<int>('collector.port');
    final collector = FakeProvider(
      outputs: const ResolvedOutputs({'collector.port': 8081}),
    );
    final agent = FakeProvider();
    final sink = CollectingEvidenceSink();
    final runner = CompositionRunner(
      composition: Composition(
        components: [
          Component(
            id: 'agent',
            provider: agent,
            dependsOn: const ['collector'],
            requires: const [port],
          ),
          Component(
            id: 'collector',
            provider: collector,
            provides: const [port],
            readiness: const HandshakeLine(pattern: 'ready '),
          ),
        ],
        readinessBudget: const Duration(seconds: 2),
      ),
      evidence: sink,
    );

    await runner.start();

    expect(collector.starts, hasLength(1));
    expect(agent.starts, hasLength(1));
    expect(agent.starts.single.dependencies.require(port), 8081);
    // Declaration order has agent first; the run must still start
    // collector first.
    final startedOrder = sink.events
        .whereType<ComponentStarting>()
        .map((final e) => e.componentId)
        .toList();
    expect(startedOrder, ['collector', 'agent']);
  });

  test('event order records starting → ready per component', () async {
    const uri = OutputRef<String>('app.vmUri');
    final app = FakeProvider(
      outputs: const ResolvedOutputs({'app.vmUri': 'ws://x'}),
    );
    final sink = CollectingEvidenceSink();
    final runner = CompositionRunner(
      composition: Composition(
        components: [
          Component(
            id: 'app',
            provider: app,
            provides: const [uri],
            readiness: const LogPattern('Dart VM Service'),
          ),
        ],
      ),
      evidence: sink,
    );
    await runner.start();
    expect(
      sink.events.map((final e) => e.kind.wire).toList(),
      ['componentStarting', 'componentReady'],
    );
    final ready = sink.events.whereType<ComponentReady>().single;
    expect(ready.outputs['app.vmUri'], 'ws://x');
  });

  test('readiness timeout cancels the start, records the cause, and tears '
      'down in reverse — never abandoning', () async {
    final slow = FakeProvider(readinessDelay: const Duration(seconds: 5));
    final quick = FakeProvider();
    final sink = CollectingEvidenceSink();
    final runner = CompositionRunner(
      composition: Composition(
        components: [
          Component(
            id: 'quick',
            provider: quick,
            lifecycle: const Lifecycle(
              stop: StopLadder(grace: Duration(milliseconds: 50)),
            ),
          ),
          Component(id: 'slow', provider: slow),
        ],
        readinessBudget: const Duration(milliseconds: 200),
      ),
      evidence: sink,
    );

    await expectLater(
      runner.start(),
      throwsA(
        isA<CompositionRunException>()
            .having((final e) => e.componentId, 'componentId', 'slow')
            .having(
              (final e) => e.cause,
              'cause',
              TerminalCause.killedOnDeadline,
            ),
      ),
    );

    expect(quick.stops, hasLength(1), reason: 'reverse teardown of started');
    expect(slow.stops, isEmpty, reason: 'never-ready component has no ref');
    final kinds = sink.events.map((final e) => e.kind.wire).toList();
    expect(kinds, contains('readinessTimeout'));
    expect(kinds.where((final k) => k == 'componentStopped'), hasLength(1));
  });

  test('start failure stops started siblings and reports teardown notes '
      'without masking the failure', () async {
    final good = FakeProvider();
    final bad = FakeProvider(startError: StateError('quota exceeded'));
    final runner = CompositionRunner(
      composition: Composition(
        components: [
          Component(id: 'good', provider: good),
          Component(id: 'bad', provider: bad),
        ],
      ),
      evidence: CollectingEvidenceSink(),
    );
    try {
      await runner.start();
      fail('start must throw');
    } on CompositionRunException catch (error) {
      expect(error.componentId, 'bad');
      expect(error.message, contains('quota exceeded'));
      expect(error.cause, TerminalCause.providerFault);
    }
    expect(good.stops, hasLength(1));
  });

  test('providers that do not resolve declared provides fail validation of '
      'the start report', () async {
    const port = OutputRef<int>('collector.port');
    final collector = FakeProvider();
    final runner = CompositionRunner(
      composition: Composition(
        components: [
          Component(
            id: 'collector',
            provider: collector,
            provides: const [port],
          ),
        ],
      ),
      evidence: CollectingEvidenceSink(),
    );
    await expectLater(
      runner.start(),
      throwsA(isA<CompositionRunException>().having(
        (final e) => e.message,
        'message',
        contains('collector.port'),
      )),
    );
    expect(
      collector.stops,
      hasLength(1),
      reason: 'started resource is stopped',
    );
  });

  test('invalid graphs fail before any side effect', () async {
    final provider = FakeProvider();
    final runner = CompositionRunner(
      composition: Composition(components: [
        Component(id: 'a', provider: provider, dependsOn: const ['ghost']),
      ]),
      evidence: CollectingEvidenceSink(),
    );
    await expectLater(runner.start(), throwsA(isA<ArgumentError>()));
    expect(provider.starts, isEmpty);
  });

  test('stopAll stops in reverse start order', () async {
    final a = FakeProvider();
    final b = FakeProvider();
    final sink = CollectingEvidenceSink();
    final runner = CompositionRunner(
      composition: Composition(components: [
        Component(id: 'a', provider: a),
        Component(id: 'b', provider: b),
      ]),
      evidence: sink,
    );
    await runner.start();
    await runner.stopAll();
    final stopOrder = sink.events
        .whereType<ComponentStopped>()
        .map((final e) => e.componentId)
        .toList();
    expect(stopOrder, ['b', 'a']);
  });
}
