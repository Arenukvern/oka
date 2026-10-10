import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

DesiredState desired(final Duration budget) => DesiredState(
  readinessBudget: budget,
  specs: const [
    ComponentSpec(
      id: 'db',
      providerName: 'process',
      readiness: TcpConnect('127.0.0.1', 5432),
    ),
    ComponentSpec(id: 'api', providerName: 'process', dependsOn: ['db']),
  ],
);

void main() {
  late Directory temp;
  late SpecStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-supervisor-store-test');
    // The root does not exist yet: the store must create it.
    store = SpecStore(Directory('${temp.path}/plans/app'));
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('SpecStore save/load', () {
    test('creates its root directory on construction', () {
      expect(store.dir.existsSync(), isTrue);
    });

    test('save then load round-trips to the same revision hashes', () {
      final written = desired(const Duration(seconds: 21));
      store.save('alpha', written);

      final loaded = store.load('alpha');
      expect(loaded, isNotNull);
      expect(loaded!.readinessBudget, const Duration(seconds: 21));
      expect(loaded.specs, hasLength(written.specs.length));
      for (final spec in written.specs) {
        expect(loaded.byId()[spec.id]!.revisionHash, spec.revisionHash);
      }
    });

    test('load of a missing plan returns null', () {
      expect(store.load('nope'), isNull);
    });

    test('save overwrites; the last write wins', () {
      store
        ..save('alpha', desired(const Duration(seconds: 5)))
        ..save('alpha', desired(const Duration(seconds: 99)));
      expect(store.load('alpha')!.readinessBudget, const Duration(seconds: 99));
    });

    test('save leaves no temp files behind (atomic rename)', () {
      store.save('alpha', desired(const Duration(seconds: 5)));
      final file = File('${store.dir.path}/alpha.json');
      expect(file.existsSync(), isTrue);
      final leftovers = store.dir
          .listSync()
          .whereType<File>()
          .where((final f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('load surfaces an unparseable document, never ignores it', () {
      File('${store.dir.path}/broken.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect(() => store.load('broken'), throwsA(isA<SpecFormatException>()));
    });
  });

  group('SpecStore names/delete', () {
    test('names are sorted and .json-stripped', () {
      store
        ..save('zeta', desired(const Duration(seconds: 5)))
        ..save('alpha', desired(const Duration(seconds: 5)))
        ..save('mid', desired(const Duration(seconds: 5)));
      // Non-plan noise is not a name.
      File('${store.dir.path}/notes.txt').writeAsStringSync('not a plan');
      expect(store.names(), ['alpha', 'mid', 'zeta']);
    });

    test('delete removes; a missing delete is a no-op', () {
      store
        ..save('alpha', desired(const Duration(seconds: 5)))
        ..delete('alpha');
      expect(store.load('alpha'), isNull);
      expect(store.names(), isEmpty);
      expect(() => store.delete('alpha'), returnsNormally);
    });
  });

  group('SpecStore name validation', () {
    for (final bad in const ['', 'a/b', '..', 'nested/../escape']) {
      test('rejects invalid plan name "$bad"', () {
        final d = desired(const Duration(seconds: 5));
        expect(() => store.save(bad, d), throwsArgumentError);
        expect(() => store.load(bad), throwsArgumentError);
        expect(() => store.delete(bad), throwsArgumentError);
      });
    }

    test('a dot in a name is fine; path separators are not', () {
      final d = desired(const Duration(seconds: 5));
      expect(() => store.save('v1.2', d), returnsNormally);
      expect(store.names(), ['v1.2']);
    });
  });
}
