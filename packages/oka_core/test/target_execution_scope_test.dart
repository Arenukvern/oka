import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

final class CountingTeardown extends BuildStep {
  CountingTeardown(this.count);
  final List<int> count;
  @override
  String get name => 'counting-teardown';
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    count.add(1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return StepResult.success();
  }
}

final class FailingTeardown extends BuildStep {
  @override
  String get name => 'failing-teardown';
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async =>
      StepResult.failure('teardown failed');
}

final class CallbackStep extends BuildStep {
  CallbackStep(this.name, this.action);
  @override
  final String name;
  final Future<StepResult> Function() action;
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) => action();
}

const _ctx = BuildContext(
  projectPath: '/tmp/x',
  buildDir: '/tmp/x/.oka_cache',
  mode: BuildMode.debug,
  config: OkaConfig.empty,
);

void main() {
  test('signal waits for current acquisition then skips later steps', () async {
    final signals = StreamController<ProcessSignal>.broadcast(sync: true);
    final acquiring = Completer<StepResult>();
    final events = <String>[];
    final scope = TargetExecutionScope(
      teardownSteps: [
        CallbackStep('cleanup', () async {
          events.add('cleanup');
          return StepResult.success();
        }),
      ],
      ctx: _ctx,
      state: PipelineState(),
      watchSignal: (_) => signals.stream,
      exitProcess: (_) {
        expect(signals.hasListener, isFalse);
        events.add('exit');
      },
    );
    final pipeline = Pipeline([
      CallbackStep('acquire', () async {
        final result = await acquiring.future;
        events.add('acquired');
        return result;
      }),
      CallbackStep('later', () async {
        events.add('later');
        return StepResult.success();
      }),
    ]);
    final run = scope.run(
      () => pipeline.run(_ctx, shouldCancel: () => scope.cancellationRequested),
    );
    signals.add(ProcessSignal.sigint);
    expect(events, isEmpty);
    acquiring.complete(StepResult.success());
    expect((await run).ok, isFalse);
    expect(events, ['acquired', 'cleanup', 'exit']);
    await signals.close();
  });

  test(
    'handlers exist during forward work and teardown runs exactly once',
    () async {
      final intSignals = StreamController<ProcessSignal>();
      final termSignals = StreamController<ProcessSignal>();
      final count = <int>[];
      final exits = <int>[];
      final scope = TargetExecutionScope(
        teardownSteps: [CountingTeardown(count)],
        ctx: _ctx,
        state: PipelineState(),
        watchSignal: (signal) => signal == ProcessSignal.sigint
            ? intSignals.stream
            : termSignals.stream,
        exitProcess: exits.add,
      );
      final forward = Completer<StepResult>();
      final run = scope.run(() => forward.future);
      intSignals.add(ProcessSignal.sigint);
      termSignals.add(ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      forward.complete(StepResult.success());
      expect((await run).ok, isTrue);
      expect(count, hasLength(1));
      expect(exits, hasLength(1));
      await intSignals.close();
      await termSignals.close();
    },
  );

  test('throwing forward error is preserved after teardown', () async {
    final count = <int>[];
    final scope = TargetExecutionScope(
      teardownSteps: [CountingTeardown(count)],
      ctx: _ctx,
      state: PipelineState(),
      watchSignal: (_) => const Stream.empty(),
      exitProcess: (_) {},
    );
    await expectLater(
      scope.run(() async => throw StateError('forward failed')),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'forward failed'),
      ),
    );
    expect(count, hasLength(1));
  });

  test('forward error survives teardown and reporter failures', () async {
    final scope = TargetExecutionScope(
      teardownSteps: [FailingTeardown()],
      ctx: _ctx,
      state: PipelineState(),
      write: (_) => throw StateError('reporter failed'),
      watchSignal: (_) => const Stream.empty(),
      exitProcess: (_) {},
    );
    await expectLater(
      scope.run(() async => throw ArgumentError('original forward error')),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'original forward error',
        ),
      ),
    );
  });

  test(
    'unsupported signal stream does not prevent forward or teardown',
    () async {
      final count = <int>[];
      final scope = TargetExecutionScope(
        teardownSteps: [CountingTeardown(count)],
        ctx: _ctx,
        state: PipelineState(),
        watchSignal: (_) => throw UnsupportedError('signals'),
        exitProcess: (_) {},
      );
      expect((await scope.run(() async => StepResult.success())).ok, isTrue);
      expect(count, hasLength(1));
    },
  );
}
