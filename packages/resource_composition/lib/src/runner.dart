/// The composition runner: topological start, stop-during-start on
/// readiness budget (never `Future.timeout` over a live start), and
/// reverse-order teardown that never masks the original failure.
///
/// The runner is provider-driven and contains **no process mechanics** —
/// those live behind `ResourceProvider` (oka's process seam is one
/// adapter). This keeps the contract package free of runtime policy while
/// still proving event order and teardown semantics with scripted fakes.
library;

import 'dart:async';

import 'component.dart';
import 'composition.dart';
import 'events.dart';
import 'evidence.dart';
import 'log_tap.dart';
import 'outputs.dart';
import 'provider.dart';

/// A start (or teardown) failure with its lifecycle meaning attached.
final class CompositionRunException implements Exception {
  CompositionRunException({
    required this.componentId,
    required this.message,
    this.cause = TerminalCause.unknown,
    this.teardownNotes = const <String>[],
  });

  final String componentId;
  final String message;
  final TerminalCause cause;

  /// Teardown errors collected while stopping already-started components —
  /// reported, but never masking [message].
  final List<String> teardownNotes;

  @override
  String toString() {
    final buffer = StringBuffer(
      'composition run failed at "$componentId" (${cause.name}): $message',
    );
    for (final note in teardownNotes) {
      buffer.write('\n  teardown note: $note');
    }
    return buffer.toString();
  }
}

/// Everything one successful [CompositionRunner.start] produced.
final class CompositionRunHandle {
  CompositionRunHandle();

  final refs = <String, ResourceRef>{};
  final outputs = <String, ResolvedOutputs>{};

  /// Reverse-start-order component ids — the teardown order.
  final teardownOrder = <String>[];
}

/// Starts a [Composition]'s components in dependency order.
final class CompositionRunner {
  CompositionRunner({required this.composition, final EvidenceSink? evidence})
    : evidence = evidence ?? _asSink(composition.evidence);

  final Composition composition;
  final EvidenceSink evidence;

  static EvidenceSink _asSink(final Object? candidate) => switch (candidate) {
        final EvidenceSink sink => sink,
        _ => CollectingEvidenceSink(),
      };

  final _started = <_Running>[];

  /// Ids of currently running components, started-first.
  List<String> get runningIds =>
      _started.map((final r) => r.component.id).toList();

  /// Starts every component in topological order (stable among
  /// independents: declaration order).
  ///
  /// Validation runs first and throws [ArgumentError] when the graph is
  /// invalid — invalid graphs fail before any side effect. On any start
  /// failure, already-started components are stopped in reverse order and
  /// the original failure is rethrown with teardown notes attached.
  Future<CompositionRunHandle> start() async {
    final report = composition.validate();
    if (!report.ok) {
      throw ArgumentError(
        'Invalid composition (validate before side effects):\n'
        '${report.render()}',
      );
    }

    final order = _topologicalOrder();
    final handle = CompositionRunHandle();

    for (final component in order) {
      final budget =
          component.readiness?.budget ?? composition.readinessBudget;
      final cancellation = Cancellation();
      final dependencies = _resolvedFrom(handle, component);
      final log = component.diagnostics.captureOutput
          ? LogTap(name: component.id)
          : null;

      evidence.add(
        ComponentStarting(componentId: component.id),
      );

      final StartReport startReport;
      try {
        final startFuture = component.provider.start(
          StartRequest(
            component: component,
            mode: StartMode.start,
            dependencies: dependencies,
            readinessBudget: budget,
            cancellation: cancellation,
            log: log,
          ),
        );
        final timer = Timer(budget, cancellation.cancel);
        try {
          startReport = await startFuture;
        } finally {
          timer.cancel();
        }
      } on StartCancelled {
        evidence.add(ReadinessTimeout(
          componentId: component.id,
          budget: budget,
        ));
        final notes = await _teardownStarted();
        throw CompositionRunException(
          componentId: component.id,
          message:
              'readiness budget of ${budget.inMilliseconds}ms fired; the '
              'start was cancelled and awaited (never abandoned)',
          cause: TerminalCause.killedOnDeadline,
          teardownNotes: notes,
        );
      } on Object catch (error) {
        evidence.add(ComponentFailed(
          componentId: component.id,
          cause: TerminalCause.providerFault,
          message: '$error',
        ));
        final notes = await _teardownStarted();
        throw CompositionRunException(
          componentId: component.id,
          message: '$error',
          cause: TerminalCause.providerFault,
          teardownNotes: notes,
        );
      }

      // Provider contract check: every declared provide must resolve.
      final unresolved = component.provides
          .where((final ref) => !startReport.outputs.contains(ref))
          .toList();
      if (unresolved.isNotEmpty) {
        evidence.add(ComponentFailed(
          componentId: component.id,
          cause: TerminalCause.providerFault,
          message: 'did not resolve declared outputs: '
              '${unresolved.map((final r) => r.id).join(', ')}',
        ));
        await component.provider.stop(
          startReport.ref,
          grace: component.lifecycle.stop.grace,
        );
        final notes = await _teardownStarted();
        throw CompositionRunException(
          componentId: component.id,
          message: 'provider did not resolve declared outputs: '
              '${unresolved.map((final r) => r.id).join(', ')}',
          cause: TerminalCause.providerFault,
          teardownNotes: notes,
        );
      }

      handle.refs[component.id] = startReport.ref;
      handle.outputs[component.id] = startReport.outputs;
      handle.teardownOrder.add(component.id);
      _started.add(
        _Running(component, startReport.ref, startReport.outputs),
      );
      evidence.add(ComponentReady(
        componentId: component.id,
        outputs: {
          for (final ref in component.provides)
            ref.id: startReport.outputs.require(ref),
        },
      ));
    }
    return handle;
  }

  /// Stops running components in reverse start order with each component's
  /// stop grace. Errors are returned per component, never thrown over
  /// siblings' stops.
  Future<List<String>> stopAll() => _teardownStarted();

  ResolvedOutputs _resolvedFrom(
    final CompositionRunHandle handle,
    final Component component,
  ) {
    final values = <String, Object?>{};
    for (final ref in component.requires) {
      for (final id in component.dependsOn) {
        final outputs = handle.outputs[id];
        if (outputs != null && outputs.contains(ref)) {
          values[ref.id] = outputs.require(ref);
        }
      }
    }
    return ResolvedOutputs(values);
  }

  Future<List<String>> _teardownStarted() async {
    final notes = <String>[];
    for (final running in _started.reversed) {
      try {
        final report = await running.component.provider.stop(
          running.ref,
          grace: running.component.lifecycle.stop.grace,
        );
        evidence.add(ComponentStopped(
          componentId: running.component.id,
          cause: report.cause ?? TerminalCause.unknown,
          message: report.message,
        ));
        if (!report.stopped) {
          final detail = report.message == null
              ? ''
              : ' — ${report.message}';
          notes.add(
            '${running.component.id}: stop reported '
            '${report.disposition.name}$detail',
          );
        }
      } on Object catch (error) {
        notes.add('${running.component.id}: stop threw: $error');
      }
    }
    _started.clear();
    return notes;
  }

  List<Component> _topologicalOrder() {
    final byId = {for (final c in composition.components) c.id: c};
    final started = <String>{};
    final order = <Component>[];
    var progress = true;
    while (order.length < composition.components.length && progress) {
      progress = false;
      for (final component in composition.components) {
        if (started.contains(component.id)) continue;
        final ready = component.dependsOn.every(
          (final dep) =>
              started.contains(dep) || !byId.containsKey(dep),
        );
        if (ready) {
          order.add(component);
          started.add(component.id);
          progress = true;
        }
      }
    }
    // Cycles are a validate-time issue; anything left unstarted is skipped
    // here and would have thrown in start() before any side effect.
    return order;
  }
}

final class _Running {
  _Running(this.component, this.ref, this.outputs);

  final Component component;
  final ResourceRef ref;
  final ResolvedOutputs outputs;
}
