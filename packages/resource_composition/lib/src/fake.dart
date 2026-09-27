/// Scripted fake provider — the R2 gate's test seam.
///
/// Proves event order, dependency-output injection, cancellation, and
/// teardown without launching real processes. It is also the template for
/// real providers: a provider that can honor [Cancellation] and verify
/// stops has the shape the contract needs.
library;

import 'dart:async';

import 'events.dart';
import 'outputs.dart';
import 'provider.dart';

/// A provider whose behavior is scripted per instance and whose calls are
/// recorded for assertions.
final class FakeProvider implements ResourceProvider {
  FakeProvider({
    this.capabilities = const ProviderCapabilities(
      readinessProbe: true,
      attach: true,
      durableIdentity: true,
    ),
    this.readinessDelay = Duration.zero,
    this.outputs = ResolvedOutputs.empty,
    this.startError,
    this.stopDisposition = StopDisposition.stopped,
    this.observation = const Observation(state: ResourceState.unknown),
    this.honorsCancellation = true,
  });

  @override
  final ProviderCapabilities capabilities;

  /// How long start pretends to take before becoming ready.
  final Duration readinessDelay;

  /// Outputs the start resolves.
  final ResolvedOutputs outputs;

  /// When set, start throws this instead of reporting.
  final Object? startError;

  /// Scripted stop outcome.
  final StopDisposition stopDisposition;

  /// Scripted inspect/reconcile observation.
  final Observation observation;

  /// Whether start honors [Cancellation] promptly (set false to simulate a
  /// contract-violating provider in tests of the runner's own guarantees).
  final bool honorsCancellation;

  /// Recorded start requests, in call order.
  final starts = <StartRequest>[];

  /// Recorded stop refs, in call order.
  final stops = <ResourceRef>[];

  /// Recorded reconcile refs, in call order.
  final reconciles = <ResourceRef>[];

  var _nextPid = 4200;

  @override
  Future<StartReport> start(final StartRequest request) async {
    starts.add(request);
    if (startError != null) {
      // ignore: only_throw_errors — the scripted error is caller-chosen.
      throw startError!;
    }
    if (readinessDelay > Duration.zero) {
      if (honorsCancellation) {
        // First of {delay elapsed, cancelled} wins — the honest shape.
        final done = Completer<void>();
        var cancelled = false;
        final timer = Timer(readinessDelay, done.complete);
        unawaited(
          request.cancellation.future.then((_) {
            cancelled = true;
            if (!done.isCompleted) done.complete();
          }),
        );
        await done.future;
        timer.cancel();
        if (cancelled) throw StartCancelled(request.component.id);
      } else {
        await Future<void>.delayed(readinessDelay);
      }
    }
    final pid = _nextPid++;
    return StartReport(
      ref: ResourceRef(
        componentId: request.component.id,
        handle: 'fake://${request.component.id}',
        pid: pid,
        identityToken: 'token-$pid',
      ),
      outputs: outputs,
    );
  }

  @override
  Future<Observation> inspect(final ResourceRef ref) async => observation;

  @override
  Future<StopReport> stop(
    final ResourceRef ref, {
    required final Duration grace,
  }) async {
    stops.add(ref);
    return StopReport(
      disposition: stopDisposition,
      cause: switch (stopDisposition) {
        StopDisposition.stopped => TerminalCause.exited,
        StopDisposition.alreadyStopped => TerminalCause.exited,
        StopDisposition.unknown => TerminalCause.unknown,
        StopDisposition.refused => null,
      },
    );
  }

  @override
  Future<Observation> reconcile(final ResourceRef ref) async {
    reconciles.add(ref);
    return observation;
  }
}
