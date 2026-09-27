/// Declarative resource composition contracts (ADR-0026).
///
/// Typed immutable component graphs validated **before side effects**;
/// readiness as a declared, budgeted concern; typed output promises
/// between components; lifecycle events with terminal causes; replaceable
/// resource providers. Zero package dependencies; no daemon; probe
/// mechanics stay in providers.
///
/// House style: components are small const values assembled by constructor
/// injection; variants rebuild the graph (`copyWith` from named parts),
/// never mutate by string key.
///
/// ```dart
/// const port = OutputRef<int>('collector.port');
///
/// final composition = Composition(components: [
///   Component(
///     id: 'collector',
///     provider: CollectorProvider(), // implements ResourceProvider
///     provides: const [port],
///     readiness: HandshakeLine(
///       pattern: 'ready ',
///       parse: (line) => {'collector.port': int.parse(line.split(' ')[1])},
///     ),
///   ),
///   Component(
///     id: 'agent',
///     provider: agentProvider,
///     dependsOn: const ['collector'],
///     requires: const [port],
///   ),
/// ]);
///
/// final report = composition.validate(); // pure
/// print(composition.explain());          // deterministic plan text
/// final handle = await CompositionRunner(
///   composition: composition,
///   evidence: CollectingEvidenceSink(),
/// ).start();
/// ```
///
/// Process *mechanics* (tree-aware stops, bounded runs, pid identity) are
/// deliberately NOT here: they live behind providers — see `oka_core`'s
/// process seam for the reference implementation.
library;

export 'src/component.dart';
export 'src/composition.dart';
export 'src/events.dart';
export 'src/evidence.dart';
export 'src/fake.dart';
export 'src/lifecycle.dart';
export 'src/log_tap.dart';
export 'src/outputs.dart';
export 'src/provider.dart';
export 'src/readiness.dart';
export 'src/runner.dart';
