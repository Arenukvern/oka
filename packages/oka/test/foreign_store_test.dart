import 'dart:io';

import 'package:oka/src/cache/host_adapters/foreign_store_diagnostics.dart';
import 'package:oka/src/cache/storage_discovery.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// ADR-0028 §4: foreign build-tool stores are inventoried (gradle, fvm new;
/// pub, flutter-sdk already known) and rendered as read-only diagnostic
/// records with advisory, user-executed actions. Oka never prunes them.
void main() {
  late Directory temp;
  late String home;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_foreign_');
    home = p.join(temp.path, 'home');
    Directory(home).createSync(recursive: true);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Map<String, String> env() => {'HOME': home, 'USERPROFILE': home};

  group('storage discovery', () {
    test('reports gradle caches and wrapper as foreign units', () async {
      Directory(p.join(home, '.gradle', 'caches')).createSync(recursive: true);
      Directory(p.join(home, '.gradle', 'wrapper')).createSync(recursive: true);

      final locations = await discoverStorageLocations(
        projectPath: temp.path,
        environment: env(),
        includeProject: false,
      );

      final gradle = locations
          .where((final l) => l.category == 'gradle-cache')
          .toList();
      expect(gradle.map((final l) => p.basename(l.path)).toSet(),
          {'caches', 'wrapper'});
      expect(gradle.every((final l) => l.ownership == 'external'), isTrue);
      expect(gradle.every((final l) => !l.prunable), isTrue,
          reason: 'oka never prunes another tool cache');
    });

    test('reports fvm versions when present', () async {
      Directory(
        p.join(home, 'fvm', 'versions', 'stable'),
      ).createSync(recursive: true);

      final locations = await discoverStorageLocations(
        projectPath: temp.path,
        environment: env(),
        includeProject: false,
      );

      final fvm = locations
          .where((final l) => l.category == 'fvm-versions')
          .toList();
      expect(fvm, hasLength(1));
      expect(fvm.first.ownership, 'external');
      expect(fvm.first.prunable, isFalse);
    });

    test('no phantom fvm unit on machines without fvm', () async {
      final locations = await discoverStorageLocations(
        projectPath: temp.path,
        environment: env(),
        includeProject: false,
      );
      expect(
        locations.where((final l) => l.category == 'fvm-versions'),
        isEmpty,
      );
    });
  });

  group('ForeignStoreDiagnosticProvider', () {
    CacheDiagnosticContext contextWith(
      final List<StorageMeasurement> measurements,
    ) => CacheDiagnosticContext(
      projects: const [],
      environment: env(),
      storage: StorageReport(locations: measurements, totalBytes: 0),
    );

    StorageMeasurement unit(
      final String category,
      final String path, {
      final int size = 1234,
    }) => StorageMeasurement(
      location: StorageLocation(
        id: '$category:$path',
        path: path,
        category: category,
        platform: 'all',
        ownership: 'external',
        prunable: false,
        note: 'foreign',
      ),
      sizeBytes: size,
      fileCount: 1,
      modifiedAt: null,
      complete: true,
      warnings: const [],
    );

    test('renders foreign records with sizes and advisory actions',
        () async {
      const provider = ForeignStoreDiagnosticProvider();
      final report = await provider.inspect(
        contextWith([
          unit('dart-pub-cache', p.join(home, '.pub-cache'), size: 1024),
          unit('gradle-cache', p.join(home, '.gradle', 'caches')),
          unit('fvm-versions', p.join(home, 'fvm', 'versions')),
          unit('android-virtual-device', p.join(home, '.android', 'avd', 'x.avd')),
        ]),
      );

      expect(report.issues, isEmpty);
      final records = report.records;
      expect(records, hasLength(3),
          reason: 'AVDs belong to the Android provider (kind emulator)');

      final pub = records.firstWhere(
        (final r) => r.path == p.join(home, '.pub-cache'),
      );
      expect(pub.kind, 'foreign-cache');
      expect(pub.metadata['size_bytes'], 1024);
      expect(pub.metadata['prunable_by_oka'], isFalse);
      expect(
        pub.actions
            .where((final a) => a.destructive)
            .map((final a) => a.argv.join(' ')),
        contains('dart pub cache clean'),
      );

      final gradle = records.firstWhere(
        (final r) => r.path == p.join(home, '.gradle', 'caches'),
      );
      expect(
        gradle.actions.map((final a) => a.argv.join(' ')),
        contains('gradle --stop'),
      );
    });

    test('records are JSON-encodable (diagnostics contract)', () async {
      const provider = ForeignStoreDiagnosticProvider();
      final report = await provider.inspect(
        contextWith([unit('dart-pub-cache', p.join(home, '.pub-cache'))]),
      );
      for (final record in report.records) {
        expect(record.toJson, returnsNormally);
      }
    });
  });
}
