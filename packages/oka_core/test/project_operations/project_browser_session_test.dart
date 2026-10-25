import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_core/project_operations.dart';
import 'package:test/test.dart';

String? _findExecutable(List<String> candidates) {
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  final sleepPath = _findExecutable(const ['/bin/sleep', '/usr/bin/sleep']);
  final posix = Platform.isWindows ? 'POSIX fixtures only' : null;

  test('a target somebody else serves is borrowed and never killed', () async {
    final tool = sleepPath!;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close();
    });
    final port = server.port;
    final root = await Directory.systemTemp.createTemp('project_session_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final registry = ProcessLeaseRegistry(Directory('${root.path}/leases'));
    final profile = ProjectOperationProfile(
      id: 'fixture',
      operations: <ProjectOperation>[
        ProjectOperation(
          id: 'serve',
          kind: ProjectOperationKind.serve,
          command: ProjectCommand(executable: tool, arguments: <String>['30']),
          endpoint: ProjectEndpoint(host: '127.0.0.1', port: port),
          readiness: ProjectReadiness.tcp(host: '127.0.0.1', port: port),
        ),
      ],
    );
    final session = ProjectBrowserSession(
      profile: profile,
      workspace: project,
      leaseRegistry: registry,
    );
    final outcome = await session.attach();
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.ownership, ProjectSessionOwnership.borrowed);
    expect(outcome.url?.port, port);
    expect(outcome.pid, isNull);
    expect(session.attached, isTrue);
    // A borrowed target is not ours: no lease record was written.
    expect(await registry.list(), isEmpty);
    final detached = await session.detach();
    expect(detached.ok, isTrue);
    // The borrowed endpoint still answers: detaching never signalled it.
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 500),
    );
    socket.destroy();
  }, skip: sleepPath == null ? 'no sleep available' : posix);

  test('a process this session spawned is owned and closed safely', () async {
    final tool = sleepPath!;
    final root = await Directory.systemTemp.createTemp('project_session_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final registry = ProcessLeaseRegistry(Directory('${root.path}/leases'));
    final ready = File('${root.path}/ready')..writeAsStringSync('ready');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final profile = ProjectOperationProfile(
      id: 'fixture',
      operations: <ProjectOperation>[
        ProjectOperation(
          id: 'serve',
          kind: ProjectOperationKind.serve,
          command: ProjectCommand(executable: tool, arguments: <String>['30']),
          endpoint: ProjectEndpoint(host: '127.0.0.1', port: port),
          readiness: ProjectReadiness.filePresent(ready.path),
        ),
      ],
    );
    final session = ProjectBrowserSession(
      profile: profile,
      workspace: project,
      leaseRegistry: registry,
    );
    final outcome = await session.attach();
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.ownership, ProjectSessionOwnership.owned);
    expect(outcome.pid, isNotNull);
    final pid = outcome.pid!;
    expect(await const HostProcessLiveness().isAlive(pid), isTrue);
    expect(await registry.read(session.effectiveLeaseId), isNotNull);
    final detached = await session.detach();
    expect(detached.ok, isTrue);
    expect(await const HostProcessLiveness().isAlive(pid), isFalse);
    expect(await registry.read(session.effectiveLeaseId), isNull);
  }, skip: sleepPath == null ? 'no sleep available' : posix);

  test(
    'a serve process that never becomes ready is stopped, not left behind',
    () async {
      final tool = sleepPath!;
      final root = await Directory.systemTemp.createTemp('project_session_');
      addTearDown(() => root.delete(recursive: true));
      final project = Directory('${root.path}/project')..createSync();
      final registry = ProcessLeaseRegistry(Directory('${root.path}/leases'));
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final profile = ProjectOperationProfile(
        id: 'fixture',
        operations: <ProjectOperation>[
          ProjectOperation(
            id: 'serve',
            kind: ProjectOperationKind.serve,
            command: ProjectCommand(
              executable: tool,
              arguments: <String>['30'],
            ),
            endpoint: ProjectEndpoint(host: '127.0.0.1', port: port),
            readiness: ProjectReadiness.filePresent('${root.path}/never'),
          ),
        ],
      );
      final session = ProjectBrowserSession(
        profile: profile,
        workspace: project,
        leaseRegistry: registry,
        readinessTimeout: const Duration(milliseconds: 400),
      );
      final outcome = await session.attach();
      expect(outcome.ok, isFalse, reason: '${outcome.toJson()}');
      expect(outcome.error, 'project_session_readiness_timeout');
      expect(outcome.pid, isNotNull);
      final pid = outcome.pid!;
      expect(await const HostProcessLiveness().isAlive(pid), isFalse);
      expect(await registry.read(session.effectiveLeaseId), isNull);
    },
    skip: sleepPath == null ? 'no sleep available' : posix,
  );

  test('a failed attach keeps the last known good target', () async {
    final tool = sleepPath!;
    final root = await Directory.systemTemp.createTemp('project_session_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final registry = ProcessLeaseRegistry(Directory('${root.path}/leases'));
    final ready = File('${root.path}/ready')..writeAsStringSync('ready');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final profile = ProjectOperationProfile(
      id: 'fixture',
      operations: <ProjectOperation>[
        ProjectOperation(
          id: 'serve',
          kind: ProjectOperationKind.serve,
          command: ProjectCommand(executable: tool, arguments: <String>['30']),
          endpoint: ProjectEndpoint(host: '127.0.0.1', port: port),
          readiness: ProjectReadiness.filePresent(ready.path),
        ),
      ],
    );
    final session = ProjectBrowserSession(
      profile: profile,
      workspace: project,
      leaseRegistry: registry,
      readinessTimeout: const Duration(milliseconds: 400),
    );
    final first = await session.attach();
    expect(first.ok, isTrue, reason: '${first.toJson()}');
    expect(first.url, isNotNull);
    ready.deleteSync();
    final second = await session.attach(replace: true);
    expect(second.ok, isFalse, reason: '${second.toJson()}');
    expect(second.error, 'project_session_readiness_timeout');
    expect(second.retainedLastKnownGood, isTrue);
    expect(session.url, first.url);
    await session.detach();
  }, skip: sleepPath == null ? 'no sleep available' : posix);

  test('a remote target is navigated to and never owned', () async {
    final root = await Directory.systemTemp.createTemp('project_session_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final registry = ProcessLeaseRegistry(Directory('${root.path}/leases'));
    const profile = ProjectOperationProfile(
      id: 'fixture',
      operations: <ProjectOperation>[
        ProjectOperation(
          id: 'serve',
          kind: ProjectOperationKind.serve,
          // A remote target is never spawned: this command is never run.
          command: ProjectCommand(
            executable: 'never-spawned',
            arguments: <String>['30'],
          ),
        ),
      ],
    );
    final session = ProjectBrowserSession(
      profile: profile,
      workspace: project,
      leaseRegistry: registry,
    );
    final target = Uri.parse('https://example.invalid/app');
    final outcome = await session.attach(url: target);
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.url, target);
    expect(outcome.ownership, ProjectSessionOwnership.borrowed);
    expect(outcome.pid, isNull);
    expect(await registry.list(), isEmpty);
  });
}
