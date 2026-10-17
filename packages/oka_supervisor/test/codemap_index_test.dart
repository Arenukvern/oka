import 'dart:convert';
import 'dart:io';
import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  final dart =
      '${File(Platform.resolvedExecutable).parent.path}/'
      '${Platform.isWindows ? 'dart.exe' : 'dart'}';
  late Directory temp;
  late String receipt;
  final now = DateTime.utc(2026, 10, 13);
  Map<String, Object?> payload(final int pid, {final String state = 'ready'}) =>
      {
        'schema': 'codemap.index-watch.v1',
        'root': temp.path,
        'pid': pid,
        'updated_at': now.toIso8601String(),
        'state': state,
        'observed_revision': 'a',
        'published_revision': 'a',
        'dirty_count': 0,
        'watcher_continuity': 'reconciled',
        'blocker': state == 'blocked' ? 'unsupported' : null,
      };
  CodemapIndexHealth read(final int pid) => CodemapIndexHealth.read(
    receiptPath: receipt,
    projectRoot: temp.path,
    pid: pid,
    now: now,
    maxAge: const Duration(seconds: 45),
  );
  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-index');
    temp = Directory(temp.resolveSymbolicLinksSync());
    receipt = '${temp.path}/receipt.json';
  });
  tearDown(() => temp.deleteSync(recursive: true));
  test('semantic states and ready consistency', () {
    for (final state in ['ready', 'pending', 'blocked']) {
      File(receipt).writeAsStringSync(jsonEncode(payload(42, state: state)));
      expect(read(42).state, state);
    }
    File(receipt).writeAsStringSync(
      jsonEncode({...payload(42), 'published_revision': 'old'}),
    );
    expect(read(42).state, 'unknown');
  });
  test('foreign, malformed, stale evidence is unknown', () {
    for (final fields in [
      {'pid': 7},
      {'root': '/foreign'},
      {'schema': 'wrong'},
      {
        'updated_at': now
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
    ]) {
      File(receipt).writeAsStringSync(jsonEncode({...payload(42), ...fields}));
      expect(read(42).state, 'unknown');
    }
    File(receipt).writeAsStringSync('{');
    expect(read(42).state, 'unknown');
  });
  test(
    'atomic executable replacement changes desired revision and resets budget',
    () {
      final executable = File('${temp.path}/codemap')..writeAsStringSync('old');
      final recipe = CodemapIndexRecipe(
        executable: executable.path,
        projectRoot: temp.path,
        policy: const SupervisionPolicy(maxRestarts: 0),
      );
      final previous = recipe.spec;
      final now = DateTime.now().toUtc();
      final record = SupervisorRecord(
        componentId: recipe.id,
        providerName: previous.providerName,
        shape: 'service',
        revisionHash: previous.revisionHash,
        epoch: 1,
        killPolicy: KillPolicy.spawned,
        startedAt: now,
        restartCount: 3,
        windowStartedAt: now,
        trigger: 'none',
        pid: 42,
        handle: 'owned',
        identityToken: 'identity',
      );
      File('${temp.path}/replacement').writeAsStringSync('new');
      File('${temp.path}/replacement').renameSync(executable.path);
      final current = recipe.spec;
      expect(current.revisionHash, isNot(previous.revisionHash));
      expect(
        current.env['executable_sha256'],
        isNot(previous.env['executable_sha256']),
      );
      final registry = MachineRegistry(root: '${temp.path}/registry');
      final scope = registry.scopeFor(temp.path);
      registry.upsert(record, scope: scope);
      final plan = planConvergence(
        desired: recipe.desired,
        snapshot: registry.snapshot(scope),
        observations: {
          recipe.id: const Observation(state: ResourceState.ready),
        },
        now: now,
      );
      expect(plan.actions.single.kind, SupervisorActionKind.restart);
      final blocked = planConvergence(
        desired: recipe.desired,
        snapshot: registry.snapshot(scope),
        observations: {
          recipe.id: const Observation(
            state: ResourceState.starting,
            message: 'old computer blocked',
          ),
        },
        now: now,
      );
      expect(blocked.actions.single.kind, SupervisorActionKind.restart);

      // Replacement changes desired revision, never process/kill authority.
      registry.upsert(
        SupervisorRecord(
          componentId: record.componentId,
          providerName: record.providerName,
          shape: record.shape,
          revisionHash: record.revisionHash,
          epoch: 1,
          killPolicy: KillPolicy.none,
          startedAt: now,
          restartCount: 3,
          windowStartedAt: now,
          trigger: 'none',
          pid: 42,
          handle: 'foreign',
          identityToken: 'identity',
        ),
        scope: scope,
      );
      final foreign = planConvergence(
        desired: recipe.desired,
        snapshot: registry.snapshot(scope),
        observations: {
          recipe.id: const Observation(state: ResourceState.ready),
        },
        now: now,
      );
      expect(foreign.actions, isEmpty);
      expect(foreign.findings.single.code, 'driftedUnowned');
    },
  );
  test(
    'symlink retarget changes identity while launch follows declared path',
    () {
      final first = File('${temp.path}/first')..writeAsStringSync('same');
      final second = File('${temp.path}/second')..writeAsStringSync('same');
      final link = Link('${temp.path}/codemap')..createSync(first.path);
      final recipe = CodemapIndexRecipe(
        executable: link.path,
        projectRoot: temp.path,
      );
      final previous = recipe.spec;
      link
        ..deleteSync()
        ..createSync(second.path);
      expect(recipe.spec.revisionHash, isNot(previous.revisionHash));
      expect(recipe.command.executable, link.path);
    },
    skip: Platform.isWindows,
  );
  test('scope contributes to revision', () {
    final a = CodemapIndexRecipe(
      executable: dart,
      projectRoot: temp.path,
      scope: {
        'exts': ['.py'],
      },
    );
    final b = CodemapIndexRecipe(
      executable: dart,
      projectRoot: temp.path,
      scope: {
        'exts': ['.dart'],
      },
    );
    expect(a.spec.revisionHash, isNot(b.spec.revisionHash));
  });
  test(
    'real worker retained when blocked; death restarts and owned stop verifies',
    () async {
      final script = File('${temp.path}/worker.dart')
        ..writeAsStringSync('''
import 'dart:io'; import 'dart:convert';
Future<void> main(List<String> args) async {
 File(args[0]).writeAsStringSync(jsonEncode({'schema':'codemap.index-watch.v1','root':args[1],'pid':pid,'updated_at':DateTime.now().toUtc().toIso8601String(),'state':'ready','observed_revision':'a','published_revision':'a','dirty_count':0}));
 stdout.writeln('codemap-index-watch-ready'); await Future<void>.delayed(const Duration(minutes:2));
}
''');
      final process = LeasedProcessProvider(
        leaseId: 'test-index',
        command: ProcessCommand(dart, [script.path, receipt, temp.path]),
        registry: ProcessLeaseRegistry.forProject(temp.path),
      );
      final provider = CodemapIndexProvider(
        process: process,
        projectRoot: temp.path,
        receiptPath: receipt,
      );
      final supervisor = Supervisor(
        projectRoot: temp.path,
        registry: MachineRegistry(root: '${temp.path}/supervisor'),
      );
      final desired = CodemapIndexRecipe(
        executable: dart,
        projectRoot: temp.path,
      ).desired;
      ResourceRef ref() {
        final r = supervisor.registry.read(supervisor.scope, 'codemap-index')!;
        return ResourceRef(
          componentId: r.componentId,
          handle: r.handle!,
          pid: r.pid,
          identityToken: r.identityToken,
        );
      }

      try {
        final evidence = CollectingEvidenceSink();
        final first = await supervisor.converge(
          desired: desired,
          factory: (_) => provider,
          evidence: evidence,
        );
        expect(
          first.started,
          1,
          reason: evidence.events.map((final e) => e.toJsonLine()).join('\n'),
        );
        expect((await provider.inspect(ref())).state, ResourceState.ready);
        File(receipt).writeAsStringSync(
          jsonEncode({
            ...payload(ref().pid!, state: 'blocked'),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        final blocked = await supervisor.converge(
          desired: desired,
          factory: (_) => provider,
        );
        expect(blocked.plan.actions, isEmpty);
        expect(blocked.plan.findings.single.message, contains('unsupported'));
        File(receipt).writeAsStringSync('{');
        final corrupt = await supervisor.converge(
          desired: desired,
          factory: (_) => provider,
        );
        expect(corrupt.plan.actions, isEmpty);
        expect(corrupt.plan.findings.single.code, 'unknown');
        expect(
          (await provider.stop(
            ref(),
            grace: const Duration(seconds: 2),
          )).stopped,
          isTrue,
        );
        expect(
          (await supervisor.converge(
            desired: desired,
            factory: (_) => provider,
          )).restarted,
          1,
        );
        expect(provider.health(ref()).current, isTrue);
      } finally {
        final record = supervisor.registry.read(
          supervisor.scope,
          'codemap-index',
        );
        if (record?.pid != null) {
          await provider.stop(ref(), grace: const Duration(seconds: 2));
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  test(
    'finite CLI exits with leased worker alive and supports owned teardown',
    () async {
      final worker = File('${temp.path}/native-fixture.dart')
        ..writeAsStringSync('''
import 'dart:io'; import 'dart:convert';
Future<void> main(List<String> args) async {
 final receipt=args[args.indexOf('--receipt')+1];
 final root=args[args.indexOf('--root')+1];
 File(receipt).writeAsStringSync(jsonEncode({'schema':'codemap.index-watch.v1','root':root,'pid':pid,'updated_at':DateTime.now().toUtc().toIso8601String(),'state':'ready','observed_revision':'a','published_revision':'a','dirty_count':0}));
 stdout.writeln('codemap-index-watch-ready');
 await Future<void>.delayed(const Duration(minutes:2));
}
''');
      final executable = File('${temp.path}/codemap-fixture')
        ..writeAsStringSync('#!/bin/sh\nexec "$dart" "${worker.path}" "\$@"\n');
      await Process.run('chmod', ['755', executable.path]);
      final args = [
        'run',
        'tool/codemap_index.dart',
        '--root',
        temp.path,
        '--executable',
        executable.path,
        '--receipt',
        receipt,
        '--passes',
        '2',
        '--interval-ms',
        '10',
      ];
      final result = await Process.run(dart, args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}', contains('"index_health":"ready"'));
      final lease = await ProcessLeaseRegistry.forProject(
        temp.path,
      ).read('codemap-index');
      expect(lease, isNotNull);
      expect(await const HostProcessLiveness().isAlive(lease!.pid), isTrue);
      final stopped = await Process.run(dart, [...args, '--stop']);
      expect(stopped.exitCode, 0, reason: '${stopped.stderr}');
      expect(await const HostProcessLiveness().isAlive(lease.pid), isFalse);
      final registry = MachineRegistry.forMachine();
      registry.delete(registry.scopeFor(temp.path), 'codemap-index');
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
  test(
    'native Codemap worker observes edits, restarts and stops',
    () async {
      final binary = Platform.environment['CODEMAP_MCP_BINARY']!;
      File(
        '${temp.path}/sample.py',
      ).writeAsStringSync('def alpha():\n    return 1\n');
      final recipe = CodemapIndexRecipe(
        executable: binary,
        projectRoot: temp.path,
        receiptPath: receipt,
        scope: {
          'exts': ['.py'],
        },
        reconcilePeriod: const Duration(milliseconds: 250),
      );
      final provider = recipe.provider();
      final supervisor = Supervisor(
        projectRoot: temp.path,
        registry: MachineRegistry(root: '${temp.path}/supervisor'),
      );
      ResourceRef ref() {
        final r = supervisor.registry.read(supervisor.scope, recipe.id)!;
        return ResourceRef(
          componentId: r.componentId,
          handle: r.handle!,
          pid: r.pid,
          identityToken: r.identityToken,
        );
      }

      Future<CodemapIndexHealth> current({final String? differentFrom}) async {
        for (var attempt = 0; attempt < 150; attempt++) {
          final health = provider.health(ref());
          if (health.current &&
              health.receipt!['published_revision'] != differentFrom) {
            return health;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        throw StateError(
          'native worker did not converge: ${provider.health(ref()).message}',
        );
      }

      try {
        final evidence = CollectingEvidenceSink();
        final started = await supervisor.converge(
          desired: recipe.desired,
          factory: (_) => provider,
          evidence: evidence,
        );
        expect(
          started.started,
          1,
          reason: evidence.events.map((final e) => e.toJsonLine()).join('\n'),
        );
        final initial = await current();
        File(
          '${temp.path}/sample.py',
        ).writeAsStringSync('def beta():\n    return 2\n');
        final changed = await current(
          differentFrom: initial.receipt!['published_revision']! as String,
        );
        expect(
          changed.receipt!['observed_revision'],
          changed.receipt!['published_revision'],
        );
        expect(
          (await provider.stop(
            ref(),
            grace: const Duration(seconds: 3),
          )).stopped,
          isTrue,
        );
        expect(
          (await supervisor.converge(
            desired: recipe.desired,
            factory: (_) => provider,
          )).restarted,
          1,
        );
        await current();
      } finally {
        final record = supervisor.registry.read(supervisor.scope, recipe.id);
        if (record?.pid != null) {
          await provider.stop(ref(), grace: const Duration(seconds: 3));
        }
      }
    },
    skip: Platform.environment['CODEMAP_MCP_BINARY'] == null
        ? 'set CODEMAP_MCP_BINARY for native integration'
        : false,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
