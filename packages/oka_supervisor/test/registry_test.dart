import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late MachineRegistry registry;
  const scope = 'scope-a';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-supervisor-test');
    registry = MachineRegistry(root: temp.path);
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  SupervisorRecord record(final String id) => SupervisorRecord(
    componentId: id,
    providerName: 'leased',
    shape: 'service',
    revisionHash: 'abc123def456',
    epoch: 1,
    killPolicy: KillPolicy.spawned,
    startedAt: DateTime.utc(2026, 10, 9),
    restartCount: 0,
    windowStartedAt: DateTime.utc(2026, 10, 9),
    trigger: 'none',
  );

  test('upsert/read/delete round-trip', () {
    registry.upsert(record('api'), scope: scope);
    final read = registry.read(scope, 'api');
    expect(read, isNotNull);
    expect(read!.componentId, 'api');
    expect(read.killPolicy, KillPolicy.spawned);
    expect(read.startedAt, DateTime.utc(2026, 10, 9));

    registry.delete(scope, 'api');
    expect(registry.read(scope, 'api'), isNull);
  });

  test('upsert is atomic and idempotent per component', () {
    registry
      ..upsert(record('api'), scope: scope)
      ..upsert(record('api').copyWith(epoch: 2, restartCount: 1), scope: scope);
    expect(registry.read(scope, 'api')!.epoch, 2);
    final files = Directory(
      '${temp.path}/records/$scope',
    ).listSync().whereType<File>().toList();
    expect(files.length, 1);
    expect(files.every((final f) => !f.path.endsWith('.tmp')), isTrue);
  });

  test('scopes isolate projects on one machine', () {
    final a = registry.scopeFor('/home/x/repo-a');
    final b = registry.scopeFor('/home/x/repo-b');
    expect(a, isNot(b));
    expect(a.length, 12);
    // Canonicalization: trailing slash and relative noise do not drift.
    expect(registry.scopeFor('/home/x/repo-a/'), a);
  });

  test('snapshot surfaces corrupt records as structured evidence', () {
    registry.upsert(record('api'), scope: scope);
    File('${temp.path}/records/$scope/broken.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');

    final snapshot = registry.snapshot(scope);
    expect(snapshot.records, hasLength(1));
    expect(snapshot.corruptPaths, hasLength(1));
    expect(snapshot['api'], isNotNull);
    expect(snapshot['broken'], isNull);
  });

  test('empty scope yields an empty snapshot', () {
    expect(registry.snapshot('missing').records, isEmpty);
  });
}
