// The oka adapter over the lease registry (ADR-0026 R3.1): a real
// process is spawned as a leased component, becomes ready through its
// declared readiness dialect, and is stopped with verified death and lease
// cleanup. POSIX-only fixtures (`sh`); Windows logic is covered by the
// seam's fake tests.
import 'dart:async';
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
  }) => Component(
    id: 'test-api',
    provider: provider,
    readiness: readiness,
    lifecycle: const Lifecycle(scope: ResourceScope.session),
    provides: provides,
  );

  StartRequest requestFor(
    final Component component, {
    final Cancellation? cancellation,
  }) => StartRequest(
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

  test(
    'cancellation before readiness stops the tree and removes the lease',
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final hideIdentity in [false, true]) {
    test('lease write failure with hidden identity $hideIdentity', () async {
      await registry.directory.parent.create(recursive: true);
      await File(registry.directory.path).writeAsString('blocked registry');
      final captured = CapturingHostLiveness(hideIdentity: hideIdentity);
      final provider = LeasedProcessProvider(
        leaseId: 'test-api',
        command: const ProcessCommand('sh', ['-c', 'exec sleep 30']),
        registry: registry,
        liveness: captured,
      );
      try {
        Object? failure;
        try {
          await provider.start(requestFor(componentFor(provider)));
        } on Object catch (error) {
          failure = error;
        }
        expect(captured.spawnedPid, isNotNull);
        expect(
          await const HostProcessLiveness().isAlive(captured.spawnedPid!),
          hideIdentity,
          reason:
              'verified identity permits cleanup; unknown identity forbids signaling',
        );
        expect(
          failure,
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('lease persistence'),
              contains(
                hideIdentity ? 'teardown unverified' : 'teardown verified',
              ),
            ),
          ),
        );
      } finally {
        // Fixture-owned cleanup also runs against the broken implementation.
        final childPid = captured.spawnedPid;
        if (childPid != null &&
            await verifyKillIdentity(
                  const HostProcessLiveness(),
                  childPid,
                  captured.spawnedToken,
                ) ==
                KillIdentity.verified) {
          await const HostProcessLiveness().kill(childPid);
        }
      }
    });
  }

  test('post-signal tree observation loss retains the owned lease', () async {
    final provider = LeasedProcessProvider(
      leaseId: 'test-api',
      command: const ProcessCommand('sh', ['-c', 'echo ready; exec sleep 30']),
      registry: registry,
      treeProbe: LostAfterFirstProbe(),
    );
    final started = await provider.start(
      requestFor(
        componentFor(
          provider,
          readiness: const HandshakeLine(pattern: 'ready'),
        ),
      ),
    );
    try {
      final stop = await provider.stop(started.ref, grace: Duration.zero);
      expect(stop.disposition, StopDisposition.unknown);
      expect(stop.message, contains('unknown'));
      expect(await registry.read('test-api'), isNotNull);
      expect(
        await const HostProcessLiveness().isAlive(started.ref.pid!),
        isFalse,
      );
    } finally {
      if (await verifyKillIdentity(
            const HostProcessLiveness(),
            started.ref.pid!,
            started.ref.identityToken,
          ) ==
          KillIdentity.verified) {
        await const HostProcessLiveness().kill(started.ref.pid!);
      }
    }
  });

  test('early child exit fails the start with the exit cause', () async {
    final provider = providerFor(const ProcessCommand('sh', ['-c', 'exit 3']));
    await expectLater(
      provider.start(
        requestFor(
          componentFor(provider, readiness: const LogPattern('never printed')),
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

  for (final code in [0, 7]) {
    test('job waits past readiness for exit $code', () async {
      final marker = '${tempDir.path}/finished';
      final provider = LeasedProcessProvider(
        leaseId: 'test-api',
        command: ProcessCommand('sh', [
          '-c',
          'echo ready; sleep 0.2; touch "$marker"; exit $code',
        ]),
        registry: registry,
        runToExit: true,
      );
      final start = provider.start(
        requestFor(
          componentFor(
            provider,
            readiness: const HandshakeLine(pattern: 'ready'),
          ),
        ),
      );
      if (code == 0) {
        await start;
      } else {
        await expectLater(start, throwsA(isA<StateError>()));
      }
      expect(
        File(marker).existsSync(),
        isTrue,
        reason: 'readiness must not be mistaken for job completion',
      );
      expect(await registry.read('test-api'), isNull);
    });
  }

  test('job cancellation after handshake stops the owned tree', () async {
    final cancellation = Cancellation();
    int? childPid;
    final provider = LeasedProcessProvider(
      leaseId: 'test-api',
      command: const ProcessCommand('sh', ['-c', r'echo ready $$; sleep 30']),
      registry: registry,
      runToExit: true,
    );
    final readiness = HandshakeLine(
      pattern: 'ready ',
      parse: (line) {
        childPid = int.parse(line.split(' ')[1]);
        Future<void>.delayed(
          const Duration(milliseconds: 100),
          cancellation.cancel,
        );
        return {};
      },
    );
    await expectLater(
      provider.start(
        requestFor(
          componentFor(provider, readiness: readiness),
          cancellation: cancellation,
        ),
      ),
      throwsA(isA<StartCancelled>()),
    );
    expect(childPid, isNotNull);
    expect(await const HostProcessLiveness().isAlive(childPid!), isFalse);
    expect(await registry.read('test-api'), isNull);
  });

  test('ready service keeps draining output after start returns', () async {
    final fixture = File('${tempDir.path}/chatty.dart')
      ..writeAsStringSync("""
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.writeln('ready');
  await stdout.flush();
  while (!File(args[0]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  for (var i = 0; i < 2048; i++) stdout.writeln('x' * 1024);
  await stdout.flush();
  File(args[1]).writeAsStringSync('flushed');
  await Future<void>.delayed(const Duration(seconds: 30));
}
""");
    final gate = File('${tempDir.path}/gate');
    final marker = File('${tempDir.path}/marker');
    final provider = providerFor(
      ProcessCommand(Platform.resolvedExecutable, [
        fixture.path,
        gate.path,
        marker.path,
      ]),
    );
    final report = await provider.start(
      requestFor(
        componentFor(
          provider,
          readiness: const HandshakeLine(pattern: 'ready'),
        ),
      ),
    );
    try {
      gate.writeAsStringSync('go');
      final clock = Stopwatch()..start();
      while (!marker.existsSync() &&
          clock.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        marker.existsSync(),
        isTrue,
        reason: 'post-readiness stdout must not block or close the child pipe',
      );
      expect((await provider.inspect(report.ref)).state, ResourceState.ready);
    } finally {
      await provider.stop(report.ref, grace: const Duration(milliseconds: 400));
    }
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
    final provider = providerFor(const ProcessCommand('sh', ['-c', 'true']));
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

  test('completed job preserves a newer lease under the same id', () async {
    final gate = File('${tempDir.path}/job-exit');
    final ready = File('${tempDir.path}/job-ready');
    final fixture = File('${tempDir.path}/job.dart')
      ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[1]).writeAsStringSync('ready');
  while (!File(args[0]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
''');
    final provider = LeasedProcessProvider(
      leaseId: 'test-api',
      command: ProcessCommand(Platform.resolvedExecutable, [
        fixture.path,
        gate.path,
        ready.path,
      ]),
      registry: registry,
      runToExit: true,
    );
    final cancellation = Cancellation();
    final start = provider.start(
      requestFor(componentFor(provider), cancellation: cancellation),
    );
    try {
      final deadline = Stopwatch()..start();
      while (!ready.existsSync()) {
        if (deadline.elapsed > const Duration(seconds: 5)) {
          throw TimeoutException('job did not reach gate');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await registry.upsert(
        ProcessLease(
          id: 'test-api',
          pid: 4242,
          kind: 'process',
          scope: LeaseScope.session,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'replacement',
          startedAt: DateTime.now().toUtc(),
          stopHint: const LeaseStopHint(tool: 'kill'),
          identity: const {processLeasePidTokenKey: 'replacement'},
        ),
      );
      gate.writeAsStringSync('exit');
      await start;
      expect((await registry.read('test-api'))?.pid, 4242);
    } finally {
      cancellation.cancel();
      await start;
    }
  });

  test(
    'unverified stop retains its lease and never signals without a tree',
    () async {
      await registry.upsert(
        ProcessLease(
          id: 'test-api',
          pid: 4242,
          kind: 'process',
          scope: LeaseScope.session,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'owned',
          startedAt: DateTime.now().toUtc(),
          stopHint: const LeaseStopHint(tool: 'kill'),
          identity: const {processLeasePidTokenKey: 'expected'},
        ),
      );
      final seam = FixtureLiveness();
      final provider = LeasedProcessProvider(
        leaseId: 'test-api',
        command: const ProcessCommand('unused'),
        registry: registry,
        liveness: seam,
        treeProbe: const MissingTree(),
      );
      final result = await provider.stop(
        const ResourceRef(
          componentId: 'test-api',
          handle: 'test-api',
          pid: 4242,
          identityToken: 'expected',
        ),
        grace: const Duration(milliseconds: 20),
      );
      expect(result.disposition, StopDisposition.unknown);
      expect(await registry.read('test-api'), isNotNull);
      expect(seam.kills, isEmpty);
    },
  );

  test(
    'inspection distinguishes matching, recycled and missing identity',
    () async {
      final provider = LeasedProcessProvider(
        leaseId: 'test-api',
        command: const ProcessCommand('unused'),
        registry: registry,
        liveness: FixtureLiveness(),
      );
      Future<Observation> observe(String? token) => provider.inspect(
        ResourceRef(
          componentId: 'test-api',
          handle: 'test-api',
          pid: 4242,
          identityToken: token,
        ),
      );
      expect((await observe('expected')).state, ResourceState.ready);
      expect((await observe('old')).state, ResourceState.stopped);
      expect((await observe(null)).state, ResourceState.unknown);
    },
  );

  test('stale stop cannot delete a replacement lease', () async {
    await registry.upsert(
      ProcessLease(
        id: 'test-api',
        pid: 4242,
        kind: 'process',
        scope: LeaseScope.session,
        ownership: LeaseOwnership.owned,
        ownerCmd: 'replacement',
        startedAt: DateTime.now().toUtc(),
        stopHint: const LeaseStopHint(tool: 'kill'),
        identity: const {processLeasePidTokenKey: 'expected'},
      ),
    );
    final provider = LeasedProcessProvider(
      leaseId: 'test-api',
      command: const ProcessCommand('unused'),
      registry: registry,
      liveness: FixtureLiveness(),
      treeProbe: const EmptyTree(),
    );
    final result = await provider.stop(
      const ResourceRef(
        componentId: 'test-api',
        handle: 'test-api',
        pid: 4141,
        identityToken: 'old',
      ),
      grace: const Duration(milliseconds: 20),
    );
    expect(result.stopped, isTrue);
    expect((await registry.read('test-api'))!.pid, 4242);
  });

  test('attach mode is refused: the provider owns what it spawns', () async {
    final provider = providerFor(const ProcessCommand('sh', ['-c', 'true']));
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

class FixtureLiveness implements ProcessLiveness {
  final kills = <int>[];
  @override
  Future<bool> isAlive(int pid) async => pid == 4242;
  @override
  Future<String?> identityToken(int pid) async => 'expected';
  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 1),
  }) async {
    kills.add(pid);
    return false;
  }
}

class MissingTree implements ProcessTreeProbe {
  const MissingTree();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

class EmptyTree implements ProcessTreeProbe {
  const EmptyTree();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async =>
      ProcessTree(rootPid: rootPid, parentOf: const {});
}

class CapturingHostLiveness implements ProcessLiveness {
  CapturingHostLiveness({this.hideIdentity = false});
  final bool hideIdentity;
  int? spawnedPid;
  String? spawnedToken;
  @override
  Future<String?> identityToken(int pid) async {
    final token = await const HostProcessLiveness().identityToken(pid);
    spawnedPid ??= pid;
    spawnedToken ??= token;
    return hideIdentity ? null : token;
  }

  @override
  Future<bool> isAlive(int pid) => const HostProcessLiveness().isAlive(pid);
  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 1)}) =>
      const HostProcessLiveness().kill(pid, grace: grace);
}

class LostAfterFirstProbe implements ProcessTreeProbe {
  int calls = 0;
  @override
  Future<ProcessTree?> enumerate(int rootPid) => calls++ == 0
      ? const HostProcessTreeProbe().enumerate(rootPid)
      : Future<ProcessTree?>.value();
}
