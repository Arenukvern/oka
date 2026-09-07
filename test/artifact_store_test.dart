import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/cache_command.dart';
import 'package:oka_android/src/build/dependency_cache.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Rewrites one entry's creation time in its per-entry index (gc seeding).
void _seedAge(final LocalArtifactStore store, final ContentKey key,
    {required final DateTime at}) {
  final indexFile = File(
    p.join(store.root, key.category, key.name, key.dirName, key.platform,
        LocalArtifactStore.indexFileName),
  );
  final record = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
  record['created'] = at.toUtc().toIso8601String();
  indexFile.writeAsStringSync(jsonEncode(record));
}

Future<File> _missWith(final String fileName, final String content) async {
  final tmpDir = await Directory.systemTemp.createTemp('oka_miss_');
  final f = File(p.join(tmpDir.path, fileName));
  await f.writeAsString(content);
  return f;
}

void main() {
  group('ContentKey', () {
    test('hash is deterministic and input-order insensitive', () {
      final a = ContentKey.compute(
        category: 'androidx',
        name: 'annotation-jvm',
        version: '1.9.1',
        inputs: const ['url:a', 'url:b'],
      );
      final b = ContentKey.compute(
        category: 'androidx',
        name: 'annotation-jvm',
        version: '1.9.1',
        inputs: const ['url:b', 'url:a'],
      );
      final c = ContentKey.compute(
        category: 'androidx',
        name: 'annotation-jvm',
        version: '1.9.1',
        inputs: const ['url:c'],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a.contentHash, hasLength(64));
      expect(a.shortHash, hasLength(12));
    });

    test('toString is the human-decodable relative path', () {
      final key = ContentKey.compute(
        category: 'aapt2',
        name: 'aapt2',
        version: '8.0.2',
        inputs: const ['build-tools-8.0.2'],
        platform: 'linux',
      );
      expect(key.dirName, matches(RegExp(r'^8\.0\.2-[0-9a-f]{12}$')));
      expect(
        key.toString(),
        matches(RegExp(r'^aapt2/aapt2/8\.0\.2-[0-9a-f]{12}/linux$')),
      );
      expect(key.relativePath, key.toString());
    });

    test('fileNameOrDefault falls back to name', () {
      final plain = ContentKey.compute(
        category: 'tools',
        name: 'kotlinc',
        version: '2.1.0',
        inputs: const ['url'],
      );
      expect(plain.fileNameOrDefault, 'kotlinc');
      final named = ContentKey.compute(
        category: 'androidx',
        name: 'annotation',
        version: '1.9.1',
        inputs: const ['url'],
        fileName: 'annotation-jvm-1.9.1.jar',
      );
      expect(named.fileNameOrDefault, 'annotation-jvm-1.9.1.jar');
    });
  });

  group('LocalArtifactStore root resolution', () {
    test('OKA_CACHE overrides home default', () {
      expect(
        LocalArtifactStore.defaultRoot(environment: {
          'OKA_CACHE': '/shared/oka-cache',
          'HOME': '/home/u',
        }),
        '/shared/oka-cache',
      );
    });

    test('falls back to ~/.oka/store without OKA_CACHE', () {
      expect(
        LocalArtifactStore.defaultRoot(environment: {'HOME': '/home/u'}),
        p.join('/home/u', '.oka', 'store'),
      );
    });

    test('explicit root wins over environment', () {
      final store = LocalArtifactStore(
        root: '/explicit',
        environment: {'OKA_CACHE': '/env'},
      );
      expect(store.root, '/explicit');
    });
  });

  group('LocalArtifactStore round-trip', () {
    late Directory tmp;
    late LocalArtifactStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_store_test_');
      store = LocalArtifactStore(root: tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('fetch runs miss once, then serves from the store', () async {
      final key = ContentKey.compute(
        category: 'androidx',
        name: 'annotation',
        version: '1.9.1',
        inputs: const ['google-maven:annotation-jvm:1.9.1'],
        fileName: 'annotation-jvm-1.9.1.jar',
      );
      var missCalls = 0;

      final first = await store.fetch(key, () {
        missCalls++;
        return _missWith('annotation-jvm-1.9.1.jar', 'jar-bytes');
      });
      expect(missCalls, 1);
      expect(await first.readAsString(), 'jar-bytes');

      // Decodable layout:
      // <root>/<category>/<name>/<version>-<hash12>/<platform>/<file>
      final rel = p.relative(first.path, from: tmp.path);
      expect(
        rel,
        '${key.category}/${key.name}/${key.dirName}/'
        '${key.platform}/annotation-jvm-1.9.1.jar',
      );
      expect(
        File(p.join(tmp.path, key.relativePath, 'oka_store.json'))
            .existsSync(),
        isTrue,
        reason: 'per-entry JSON index must exist',
      );

      final second = await store.fetch(key, () {
        missCalls++;
        return _missWith('annotation-jvm-1.9.1.jar', 'jar-bytes');
      });
      expect(missCalls, 1, reason: 'second fetch must be a hit');
      expect(second.path, first.path);
    });

    test('find and entries expose the entry; delete removes it', () async {
      final key = ContentKey.compute(
        category: 'tools',
        name: 'r8',
        version: '8.3.37',
        inputs: const ['r8-url'],
        fileName: 'r8.jar',
      );
      final file = await store.fetch(
        key,
        () => _missWith('r8.jar', '0123456789'),
      );

      final found = await store.find(key);
      expect(found, isNotNull);
      expect(found!.path, file.path);
      expect(found.sizeBytes, 10);

      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.key, key);

      expect(await store.delete(key), isTrue);
      expect(
        Directory(p.join(
          tmp.path, key.category, key.name, key.dirName, key.platform,
        )).existsSync(),
        isFalse,
      );
      expect(await store.entries(), isEmpty);
      expect(await store.delete(key), isFalse);
    });

    test('hand-deleted files are re-fetched, never silently reused',
        () async {
      final key = ContentKey.compute(
        category: 'tools',
        name: 'd8',
        version: '1.0',
        inputs: const ['d8-url'],
        fileName: 'd8.jar',
      );
      var missCalls = 0;
      await store.fetch(key, () {
        missCalls++;
        return _missWith('d8.jar', 'content');
      });
      final stored = (await store.entries()).single;
      await File(stored.path).delete();

      final again = await store.fetch(key, () {
        missCalls++;
        return _missWith('d8.jar', 'content-2');
      });
      expect(missCalls, 2);
      expect(await again.readAsString(), 'content-2');
    });

    test('corrupt index files are skipped, never fatal', () async {
      final bad = Directory(
        p.join(tmp.path, 'maven', 'x', '1.0-000000000000', 'any'),
      )..createSync(recursive: true);
      File(p.join(bad.path, 'oka_store.json')).writeAsStringSync('{not json');
      expect(await store.entries(), isEmpty);
    });
  });

  group('LocalArtifactStore purge', () {
    late Directory tmp;
    late LocalArtifactStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_purge_test_');
      store = LocalArtifactStore(root: tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<ContentKey> seed({
      required final String name,
      required final DateTime createdAt,
      required final int sizeBytes,
      final String? category,
    }) async {
      final key = ContentKey.compute(
        category: category ?? 'gc',
        name: name,
        version: '1.0.0',
        inputs: ['seed:$name'],
        fileName: '$name.bin',
      );
      final file = await store.fetch(
        key,
        () => _missWith('$name.bin', 'x' * sizeBytes),
      );
      expect(file.lengthSync(), sizeBytes);
      _seedAge(store, key, at: createdAt);
      return key;
    }

    test('purge older-than removes only old entries', () async {
      await seed(
        name: 'old',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 40)),
        sizeBytes: 100,
      );
      await seed(
        name: 'new',
        createdAt: DateTime.now().toUtc(),
        sizeBytes: 200,
      );

      final result = await store.purge(olderThan: const Duration(days: 30));
      expect(result.deleted, 1);
      expect(result.bytesFreed, 100);
      final left = await store.entries();
      expect(left, hasLength(1));
      expect(left.single.key.name, 'new');
    });

    test('purge max-total-bytes evicts oldest until under budget', () async {
      await seed(
        name: 'oldest',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
        sizeBytes: 300,
      );
      await seed(
        name: 'middle',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 20)),
        sizeBytes: 300,
      );
      await seed(
        name: 'newest',
        createdAt: DateTime.now().toUtc(),
        sizeBytes: 100,
      );

      final result = await store.purge(maxTotalBytes: 500);
      expect(result.deleted, 1);
      expect(result.bytesFreed, 300);
      final left = await store.entries();
      expect(left, hasLength(2));
      expect(left.map((final e) => e.key.name), isNot(contains('oldest')));
    });

    test('dry run reports without deleting', () async {
      await seed(
        name: 'old',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 40)),
        sizeBytes: 100,
      );
      final result = await store.purge(
        olderThan: const Duration(days: 1),
        dryRun: true,
      );
      expect(result.deleted, 1);
      expect(result.bytesFreed, 100);
      expect(await store.entries(), hasLength(1));
    });

    test('category filter scopes the purge', () async {
      await seed(
        name: 'keep',
        category: 'keepme',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 40)),
        sizeBytes: 10,
      );
      await seed(
        name: 'drop',
        category: 'dropme',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 40)),
        sizeBytes: 10,
      );

      final result = await store.purge(
        olderThan: const Duration(days: 1),
        category: 'dropme',
      );
      expect(result.deleted, 1);
      final left = await store.entries();
      expect(left, hasLength(1));
      expect(left.single.key.category, 'keepme');
    });
  });

  group('foreign-layout registration (producer-written index)', () {
    late Directory tmp;
    late LocalArtifactStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_register_test_');
      store = LocalArtifactStore(root: tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('producer index is discovered and the entry is purgeable',
        () async {
      // Simulate the Maven layout: <root>/maven/g/a/1.0/{artifact, index}
      final versionDir = Directory(
        p.join(tmp.path, 'maven', 'androidx.core', 'core', '1.13.1'),
      )..createSync(recursive: true);
      final artifact = File(p.join(versionDir.path, 'core-1.13.1.aar'))
        ..writeAsStringSync('aar-bytes');
      File(p.join(versionDir.path, 'core-1.13.1-classes.jar'))
          .writeAsStringSync('classes');
      final key = ContentKey.compute(
        category: 'maven',
        name: 'androidx.core:core',
        version: '1.13.1',
        platform: 'jvm',
        inputs: const ['maven:androidx.core:core:1.13.1'],
      );
      File(p.join(versionDir.path, 'oka_store.json')).writeAsStringSync(
        jsonEncode({
          'category': key.category,
          'name': key.name,
          'version': key.version,
          'hash': key.contentHash,
          'platform': key.platform,
          'file': 'core-1.13.1.aar',
          'size_bytes': artifact.lengthSync(),
          'created': DateTime.now().toUtc().toIso8601String(),
          'source': 'maven-resolver',
        }),
      );

      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.key, key);
      expect(entries.single.sizeBytes, 9);
      expect(entries.single.source, 'maven-resolver');

      // find() resolves registered entries that live off their own path.
      expect((await store.find(key))!.path, artifact.path);

      // Deleting the entry removes the whole version directory
      // (artifact + classes jar) — the gc unit for Maven entries.
      expect(await store.delete(key), isTrue);
      expect(versionDir.existsSync(), isFalse);
      expect(await store.entries(), isEmpty);
    });
  });

  group('Maven resolver registers into the store', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_maven_store_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('downloaded artifact is visible as a store entry', () async {
      final cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'maven'),
        allowNetwork: false,
      );
      const coord = MavenCoordinate(
        groupId: 'androidx.annotation',
        artifactId: 'annotation-jvm',
        version: '1.9.1',
      );
      final jar = await cache.resolve(coord, fixtureBytes: minimalJarBytes());
      expect(File(jar.jarPath).existsSync(), isTrue);

      final store = LocalArtifactStore(root: tmp.path);
      final entries = await store.entries();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.key.category, 'maven');
      expect(entry.key.name, 'androidx.annotation:annotation-jvm');
      expect(entry.key.version, '1.9.1');
      expect(entry.key.platform, 'jvm');
      expect(entry.sizeBytes, greaterThan(0));
      expect(entry.source, 'maven-resolver');
      expect(File(entry.path).existsSync(), isTrue);
    });
  });

  group('CacheCommand', () {
    late Directory tmp;
    late LocalArtifactStore store;
    final output = StringBuffer();

    setUp(() async {
      output.clear();
      tmp = await Directory.systemTemp.createTemp('oka_cache_cmd_');
      store = LocalArtifactStore(root: tmp.path);
      final key = ContentKey.compute(
        category: 'androidx',
        name: 'annotation',
        version: '1.9.1',
        inputs: const ['google-maven:annotation-jvm:1.9.1'],
        fileName: 'annotation-jvm-1.9.1.jar',
      );
      await store.fetch(
        key,
        () => _missWith('annotation-jvm-1.9.1.jar', 'jar-bytes'),
      );
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('list shows the decodable entry table', () async {
      await CacheCommand(out: output.writeln, store: store).run(['list']);
      final text = output.toString();
      expect(text, contains('androidx'));
      expect(text, contains('annotation'));
      expect(text, contains('1 entries'));
    });

    test('why maps a logical artifact to its key and path', () async {
      await CacheCommand(out: output.writeln, store: store)
          .run(['why', 'androidx/annotation/1.9.1']);
      final text = output.toString();
      expect(text, contains('androidx/annotation/1.9.1-'));
      expect(text, contains('annotation-jvm-1.9.1.jar'));
      expect(text, contains('path:'));
    });

    test('why fails for unknown artifacts', () async {
      final cmd = CacheCommand(out: output.writeln, store: store);
      await expectLater(
        cmd.run(['why', 'nope/nothing']),
        throwsA(isA<CacheCommandError>()),
      );
    });

    test('gc refuses to run without explicit criteria (never interactive)',
        () async {
      await expectLater(
        CacheCommand(out: output.writeln, store: store).run(['gc']),
        throwsA(isA<CacheCommandError>()),
      );
      expect(output.toString(), contains('explicit criteria'));
    });

    test('gc --dry-run reports without deleting', () async {
      _seedAge(
        store,
        (await store.entries()).single.key,
        at: DateTime.now().toUtc().subtract(const Duration(days: 40)),
      );
      await CacheCommand(out: output.writeln, store: store)
          .run(['gc', '--older-than=30d', '--dry-run']);
      final text = output.toString();
      expect(text, contains('Would purge'));
      expect(text, contains('1 entries'));
      expect(await store.entries(), hasLength(1));
    });

    test('gc --older-than purges aged entries', () async {
      _seedAge(
        store,
        (await store.entries()).single.key,
        at: DateTime.now().toUtc().subtract(const Duration(days: 40)),
      );
      await CacheCommand(out: output.writeln, store: store)
          .run(['gc', '--older-than=30d']);
      expect(output.toString(), contains('Purged 1 entries'));
      expect(await store.entries(), isEmpty);
    });
  });
}
