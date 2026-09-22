import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    final created = Directory.systemTemp.createTempSync('oka-android-diag-');
    root = Directory(created.resolveSymbolicLinksSync());
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('combines custom ini and avd directory with metadata and sizes', () async {
    final avd = Directory(p.join(root.path, 'devices', 'Pixel.avd'))
      ..createSync(recursive: true);
    File(
      p.join(root.path, 'Pixel.ini'),
    ).writeAsStringSync('path=${avd.path}\ntarget=android-35\n');
    File(p.join(avd.path, 'config.ini')).writeAsStringSync(
      'avd.ini.displayname=Pixel API 35\nhw.device.name=pixel\n'
      'abi.type=x86_64\nimage.sysdir.1=system-images/android-35/google_apis/x86_64/\n',
    );
    File(
      p.join(avd.path, 'userdata-qemu.img'),
    ).writeAsBytesSync(List.filled(7, 1));
    Directory(p.join(avd.path, 'snapshots')).createSync();
    File(
      p.join(avd.path, 'snapshots', 'snap'),
    ).writeAsBytesSync(List.filled(3, 1));

    final report = await StorageInventory(
      locations: [
        _location(p.join(root.path, 'Pixel.ini'), 'ini'),
        _location(avd.path, 'avd'),
      ],
    ).scan();
    final result = await const AndroidCacheDiagnosticProvider().inspect(
      CacheDiagnosticContext(
        projects: const [],
        environment: const {},
        storage: report,
        observedAt: DateTime.utc(2026),
      ),
    );

    expect(result.issues, isEmpty);
    expect(result.records, hasLength(1));
    final record = result.records.single;
    expect(record.metadata['display_name'], 'Pixel API 35');
    expect(record.metadata['device_name'], 'pixel');
    expect(record.metadata['api_level'], 35);
    expect(record.metadata['abi'], 'x86_64');
    expect(
      record.storagePaths,
      contains(p.join(avd.path, 'userdata-qemu.img')),
    );
    expect(record.storagePaths, contains(p.join(avd.path, 'snapshots')));
  });

  test(
    'reports corrupt metadata while preserving valid siblings and session link',
    () async {
      final good = Directory(p.join(root.path, 'good.avd'))..createSync();
      File(
        p.join(root.path, 'custom-id.ini'),
      ).writeAsStringSync('path=${good.path}\navd=CustomAvdId\n');
      File(
        p.join(good.path, 'config.ini'),
      ).writeAsStringSync('avd.ini.displayname=Good\ntarget=android-34\n');
      final bad = Directory(p.join(root.path, 'bad.avd'))..createSync();
      File(
        p.join(bad.path, 'config.ini'),
      ).writeAsStringSync('not-an-ini-line\n');
      final project = Directory(p.join(root.path, 'project'))..createSync();
      final registry = ProcessLeaseRegistry.forProject(project.path);
      await registry.upsert(
        ProcessLease(
          id: 'emulator-good',
          pid: 0,
          kind: 'android-emulator',
          identity: const {'avd': 'CustomAvdId'},
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'oka run emulator',
          startedAt: DateTime.utc(2026),
          stopHint: const LeaseStopHint(tool: 'adb'),
        ),
      );

      final report = await StorageInventory(
        locations: [
          _location(good.path, 'good'),
          _location(p.join(root.path, 'custom-id.ini'), 'custom-ini'),
          _location(bad.path, 'bad'),
        ],
      ).scan();
      final result = await const AndroidCacheDiagnosticProvider().inspect(
        CacheDiagnosticContext(
          projects: [project.path],
          environment: const {},
          storage: report,
        ),
      );

      expect(result.records, hasLength(2));
      expect(
        result.issues.map((issue) => issue.code),
        contains('malformed_metadata'),
      );
      expect(
        result.records
            .singleWhere((record) => record.label == 'Good')
            .relatedIds,
        contains(CacheDiagnosticIds.session(project.path, 'emulator-good')),
      );
    },
  );
}

StorageLocation _location(String path, String id) => StorageLocation(
  id: id,
  path: path,
  category: 'android-virtual-device',
  platform: 'android',
  ownership: 'descriptive',
  prunable: false,
);
