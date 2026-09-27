// The oka adapter over the lease registry (ADR-0026 R3.1): a real
// process is spawned as a leased component, becomes ready through its
// declared readiness dialect, and is stopped with verified death and lease
// cleanup. POSIX-only fixtures (`sh`); Windows logic is covered by the
// seam's fake tests.
import 'dart:io';

// `allOf` here is the matcher; the readiness combinator is unused below.
import 'package:oka_core/oka_core.dart';
import 'package:resource_composition/resource_composition.dart' hide allOf;
import 'package:test/test.dart';

void main() {
  if (Platform.isWindows) {
    return;
  }
  late Directory tempDir;
  late ProcessLeaseRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('oka-leased-provider');
    registry = ProcessLeaseRegistry(
      Directory('${tempDir.path}/.oka_cache/processes'),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LeasedProcessProvider providerFor(final ProcessCommand command) =>
      LeasedProcessProvider(
        leaseId: 'test-api',
        command: command,
        registry: registry,
      );

  Component componentFor(
    final ResourceProvider provider, {
    final Readiness? readiness,
    final List<OutputRef<Object?>> provides = const [],
  }) =>
      Component(
        id: 'test-api',
        provider: provider,
        readiness: readiness,
        lifecycle: const Lifecycle(scope: ResourceScope.session),
        provides: provides,
      );

  StartRequest requestFor(
    final Component component, {
    final Cancellation? cancellation,
  }) =>
      StartRequest(
        component: component,
        mode: StartMode.start,
        dependencies: ResolvedOutputs.empty,
        readinessBudget: const Duration(seconds: 10),
        cancellation: cancellation ?? Cancellation(),
      );

  test('spawns a leased process, resolves handshake outputs, and stops '
      'with verified death', () async {
    const port = OutputRef<int>('test-api.port');
    final provider = providerFor(
      const ProcessCommand('sh', ['-c', 'echo ready 8081; sleep 30']),
    );
    final report = await provider.start(
      requestFor(
        componentFor(
          provider,
          // A closure cannot be const; the pattern string below still is.
          readiness: HandshakeLine(
            pattern: 'ready ',
            parse: (line) => {'test-api.port': int.parse(line.split(' ')[1])},
          ),
          provides: const [port],
        ),
      ),
    );

    expect(report.outputs.require(port), 8081);
    expect(report.ref.pid, greaterThan(0));
    final lease = await registry.read('test-api');
    expect(lease, isNotNull);
    expect(lease!.ownership, LeaseOwnership.owned);
    expect(lease.scope, LeaseScope.session);

    const liveness = HostProcessLiveness();
    final stop = await provider.stop(
      report.ref,
      grace: const Duration(milliseconds: 400),
    );
    expect(stop.disposition, StopDisposition.stopped);
    expect(
      await registry.read('test-api'),
      isNull,
      reason: 'the lease is removed after a verified stop',
    );
    expect(await liveness.isAlive(report.ref.pid!), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cancellation before readiness stops the tree and removes the lease',
      () async {
    final provider = providerFor(
      const ProcessCommand('sh', ['-c', 'sleep 30']),
    );
    final cancellation = Cancellation();
    final start = provider.start(
      requestFor(
        componentFor(
          provider,
          readiness: const FilePresent('/nonexistent-oka-readiness-marker'),
        ),
        cancellation: cancellation,
      ),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 300),
      cancellation.cancel,
    );
    await expectLater(start, throwsA(isA<StartCancelled>()));
    expect(
      await registry.read('test-api'),
      isNull,
      reason: 'a cancelled start leaves no lease behind',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('early child exit fails the start with the exit cause', () async {
    final provider = providerFor(
      const ProcessCommand('sh', ['-c', 'exit 3']),
    );
    await expectLater(
      provider.start(
        requestFor(
          componentFor(
            provider,
            readiness: const LogPattern('never printed'),
          ),
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (final e) => e.message,
          'message',
          allOf(contains('exited (code 3)'), contains('test-api')),
        ),
      ),
    );
    expect(
      await registry.read('test-api'),
      isNull,
      reason: 'a failed start leaves nothing running and no lease',
    );
  });

  test('borrowed leases are refused at stop (owned-only teardown)', () async {
    await registry.upsert(
      ProcessLease(
        id: 'test-api',
        pid: 999999,
        kind: 'process',
        scope: LeaseScope.ephemeral,
        ownership: LeaseOwnership.borrowed,
        ownerCmd: 'someone-else',
        startedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        stopHint: const LeaseStopHint(tool: 'kill'),
      ),
    );
    final provider = providerFor(
      const ProcessCommand('sh', ['-c', 'true']),
    );
    final stop = await provider.stop(
      const ResourceRef(
        componentId: 'test-api',
        handle: 'test-api',
        pid: 999999,
      ),
      grace: const Duration(milliseconds: 50),
    );
    expect(stop.disposition, StopDisposition.refused);
    expect(
      await registry.read('test-api'),
      isNotNull,
      reason: 'the borrowed lease is retained',
    );
  });

  test('attach mode is refused: the provider owns what it spawns', () async {
    final provider = providerFor(
      const ProcessCommand('sh', ['-c', 'true']),
    );
    await expectLater(
      provider.start(
        StartRequest(
          component: componentFor(provider),
          mode: StartMode.attach,
          dependencies: ResolvedOutputs.empty,
          readinessBudget: const Duration(seconds: 1),
          cancellation: Cancellation(),
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
