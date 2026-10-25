import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Supervisor supervisor;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('app_supervisor_');
    supervisor = Supervisor(
      projectRoot: temp.path,
      registry: MachineRegistry(root: '${temp.path}/registry'),
    );
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'real command runs in project cwd with exact argv and durable result',
    () async {
      final script = File('${temp.path}/command.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  File('result').writeAsStringSync(args.single);
  print('finished');
}
''');
      final desired = DesiredState(
        specs: [
          ComponentSpec(
            id: 'check',
            providerName: 'process',
            policy: const SupervisionPolicy(shape: SupervisionShape.job),
            env: {
              'command': Platform.resolvedExecutable,
              'args-json': jsonEncode([script.path, 'two words']),
            },
          ),
        ],
      );
      final session = AppSupervisorSession(
        supervisor: supervisor,
        loadDesired: () async => desired,
        factoryFor: (desired) => SupervisorProcessProvider(
          desired: desired,
          projectRoot: temp.path,
        ).factory,
      );
      final first = session.converge();
      expect(identical(first, session.converge()), isTrue);
      expect((await first).ok, isTrue);
      expect(File('${temp.path}/result').readAsStringSync(), 'two words');
      expect(
        supervisor.registry.snapshot(supervisor.scope)['check']!.lastRun,
        'succeeded',
      );
      expect((await session.converge()).started, 0);
      await session.close();
      await expectLater(session.converge(), throwsStateError);
    },
  );

  test(
    'caller cancellation joins provider and prevents subsequent starts',
    () async {
      final provider = _BlockingProvider();
      final session = AppSupervisorSession(
        supervisor: supervisor,
        loadDesired: () async => const DesiredState(
          specs: [
            ComponentSpec(id: 'first', providerName: 'test'),
            ComponentSpec(id: 'second', providerName: 'test'),
          ],
        ),
        factoryFor: (_) =>
            (_) => provider,
      );
      final run = session.converge();
      await provider.entered.future;
      final closing = session.close();
      final report = await run;
      await closing;
      expect(report.cancelled, isTrue);
      expect(report.ok, isFalse);
      expect(provider.cleaned, isTrue);
      expect(provider.starts, 1);
    },
  );

  test('session only stops its own unchanged generations', () async {
    final provider = FakeProvider();
    final session = AppSupervisorSession(
      supervisor: supervisor,
      loadDesired: () async => const DesiredState(
        specs: [ComponentSpec(id: 'service', providerName: 'test')],
      ),
      factoryFor: (_) =>
          (_) => provider,
    );
    await session.converge();
    final current = supervisor.registry.snapshot(supervisor.scope)['service']!;
    supervisor.registry.upsert(
      current.copyWith(epoch: current.epoch + 1),
      scope: supervisor.scope,
    );
    expect(await session.close(), isEmpty);
  });

  test(
    'explicit stop joins owned services and leaves the session reusable',
    () async {
      final provider = FakeProvider();
      final session = AppSupervisorSession(
        supervisor: supervisor,
        loadDesired: () async => const DesiredState(
          specs: [ComponentSpec(id: 'service', providerName: 'test')],
        ),
        factoryFor: (_) =>
            (_) => provider,
      );
      await session.converge();
      expect((await session.stop()).single.stopped, isTrue);
      expect(provider.stops, hasLength(1));
      // Stop is distinct from close: the app can request a fresh observation.
      await session.converge();
      await session.close();
      expect(provider.stops, hasLength(1));
    },
  );

  test('invalid argv never launches a process', () {
    expect(
      () => SupervisorProcessProvider.commandArguments({'args-json': '[1]'}),
      throwsFormatException,
    );
    expect(
      () => SupervisorProcessProvider.commandArguments({
        'args': 'a',
        'args-json': '[]',
      }),
      throwsFormatException,
    );
  });
}

final class _BlockingProvider implements ResourceProvider {
  final entered = Completer<void>();
  bool cleaned = false;
  int starts = 0;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Future<StartReport> start(StartRequest request) async {
    starts++;
    entered.complete();
    await request.cancellation.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cleaned = true;
    throw StartCancelled(request.component.id);
  }

  @override
  Future<Observation> inspect(ResourceRef ref) async =>
      const Observation(state: ResourceState.unknown);
  @override
  Future<Observation> reconcile(ResourceRef ref) => inspect(ref);
  @override
  Future<StopReport> stop(ResourceRef ref, {required Duration grace}) async =>
      const StopReport(disposition: StopDisposition.stopped);
}
