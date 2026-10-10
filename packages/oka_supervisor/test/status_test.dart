import 'dart:convert';
import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late MachineRegistry registry;
  const scope = 'status-scope';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-supervisor-status-test');
    registry = MachineRegistry(root: temp.path);
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  const spec = ComponentSpec(id: 'api', providerName: 'process');

  SupervisorRecord record(
    final String id, {
    final String revisionHash = 'aaaaaaaaaaaa',
    final int restartCount = 0,
    final String? lastRun,
  }) => SupervisorRecord(
    componentId: id,
    providerName: 'process',
    shape: 'service',
    revisionHash: revisionHash,
    epoch: 1,
    killPolicy: KillPolicy.spawned,
    startedAt: DateTime.utc(2026, 10, 9),
    restartCount: restartCount,
    windowStartedAt: DateTime.utc(2026, 10, 9),
    trigger: 'none',
    pid: 4242,
    lastRun: lastRun,
  );

  group('projectStatus', () {
    test('empty snapshot and no desired state is empty', () {
      final statuses = projectStatus(
        snapshot: const RegistrySnapshot(records: []),
      );
      expect(statuses, isEmpty);
    });

    test('desired-only spec is absent, with the desired hash set', () {
      final statuses = projectStatus(
        snapshot: const RegistrySnapshot(records: []),
        desired: const DesiredState(specs: [spec]),
      );
      expect(statuses, hasLength(1));
      final status = statuses.single;
      expect(status.componentId, 'api');
      expect(status.present, isFalse);
      expect(status.providerName, 'process');
      expect(status.shape, 'service');
      expect(status.desiredRevisionHash, spec.revisionHash);
      expect(status.revisionHash, isNull);
      expect(status.drifted, isFalse);
      expect(status.trigger, 'none');
    });

    test('record-only ids come after desired ones, sorted', () {
      registry
        ..upsert(record('zz-worker'), scope: scope)
        ..upsert(record('aa-worker'), scope: scope);
      final statuses = projectStatus(
        snapshot: registry.snapshot(scope),
        desired: const DesiredState(
          specs: [
            ComponentSpec(id: 'api', providerName: 'process'),
            ComponentSpec(id: 'db', providerName: 'process'),
          ],
        ),
      );
      expect(
        [for (final status in statuses) status.componentId],
        ['api', 'db', 'aa-worker', 'zz-worker'],
      );
      final worker = statuses[2];
      expect(worker.present, isTrue);
      expect(worker.desiredRevisionHash, isNull);
      expect(worker.revisionHash, 'aaaaaaaaaaaa');
      expect(worker.pid, 4242);
      expect(worker.killPolicy, 'spawned');
      expect(worker.epoch, 1);
      expect(worker.drifted, isFalse);
    });

    test('matching revision hash is not drifted', () {
      registry.upsert(
        record('api', revisionHash: spec.revisionHash),
        scope: scope,
      );
      final statuses = projectStatus(
        snapshot: registry.snapshot(scope),
        desired: const DesiredState(specs: [spec]),
      );
      expect(statuses.single.drifted, isFalse);
      expect(statuses.single.present, isTrue);
    });

    test('a differing revision hash is drifted', () {
      registry.upsert(
        record('api', revisionHash: 'bbbbbbbbbbbb'),
        scope: scope,
      );
      final statuses = projectStatus(
        snapshot: registry.snapshot(scope),
        desired: const DesiredState(specs: [spec]),
      );
      final status = statuses.single;
      expect(status.drifted, isTrue);
      expect(status.revisionHash, 'bbbbbbbbbbbb');
      expect(status.desiredRevisionHash, spec.revisionHash);
    });

    test('jobs carry lastRun from the record', () {
      registry.upsert(record('nightly', lastRun: 'succeeded'), scope: scope);
      final statuses = projectStatus(snapshot: registry.snapshot(scope));
      expect(statuses.single.lastRun, 'succeeded');
    });
  });

  group('statusJson', () {
    test('carries statuses and corrupt record paths', () {
      final statuses = projectStatus(
        snapshot: const RegistrySnapshot(records: []),
        desired: const DesiredState(specs: [spec]),
      );
      final json = statusJson(
        statuses: statuses,
        corruptPaths: ['/tmp/records/broken.json'],
      );
      final document = jsonDecode(json) as Map<String, Object?>;
      expect(document['corruptRecords'], ['/tmp/records/broken.json']);
      final entries = document['statuses']! as List<Object?>;
      expect(entries, hasLength(1));
      final entry = entries.single! as Map<String, Object?>;
      expect(entry['componentId'], 'api');
      expect(entry['desiredRevisionHash'], spec.revisionHash);
    });

    test('omits null fields and always reports drifted', () {
      final json = statusJson(statuses: const [], corruptPaths: []);
      final document = jsonDecode(json) as Map<String, Object?>;
      expect(document['statuses'], isEmpty);
      expect(document['corruptRecords'], isEmpty);

      const drifted = ComponentStatus(
        componentId: 'api',
        present: true,
        drifted: true,
      );
      final driftedDocument =
          jsonDecode(statusJson(statuses: [drifted])) as Map<String, Object?>;
      final entry =
          (driftedDocument['statuses']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(entry.containsKey('pid'), isFalse);
      expect(entry.containsKey('lastRun'), isFalse);
      expect(entry['drifted'], isTrue);
    });
  });

  group('renderStatus', () {
    test('contains the DRIFT column header and component ids', () {
      final statuses = projectStatus(
        snapshot: const RegistrySnapshot(records: []),
        desired: const DesiredState(specs: [spec]),
      );
      final rendered = renderStatus(statuses);
      expect(rendered, contains('DRIFT'));
      expect(rendered, contains('PRESENT'));
      expect(rendered, contains('TRIGGER'));
      expect(rendered, contains('api'));
      // Header first, one row per status.
      final lines = rendered.split('\n');
      expect(lines.first.trim(), startsWith('ID'));
      expect(lines, hasLength(statuses.length + 1));
    });

    test('renders drifted and absent rows distinctly', () {
      final rendered = renderStatus(const [
        ComponentStatus(
          componentId: 'api',
          present: true,
          shape: 'service',
          pid: 4242,
          drifted: true,
          trigger: 'none',
        ),
        ComponentStatus(
          componentId: 'db',
          present: false,
          shape: 'service',
          trigger: 'interval:3600s',
        ),
      ]);
      final lines = rendered.split('\n');
      expect(lines[1], contains('drifted'));
      expect(lines[1], contains('4242'));
      expect(lines[2], contains('interval:3600s'));
      // The PRESENT column distinguishes the two rows.
      expect(lines[1], contains(' yes '));
      expect(lines[2], contains(' no '));
    });
  });
}
