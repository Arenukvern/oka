import 'dart:io';

import 'package:oka_android/src/build/r8_tool.dart';
import 'package:oka_android/src/maven_resolver.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// ADR-0028 §1: single maven root (legacy migration), byte-verified warm
/// hits, and store-resident R8.
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_maven_root_');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Map<String, String> envFor(final Directory home) => {
    'HOME': home.path,
    'USERPROFILE': home.path,
    'OKA_CACHE': p.join(home.path, 'store'),
  };

  group('defaultCacheRoot migration', () {
    test('migrates the legacy root by rename on first use', () {
      final home = Directory.systemTemp.createTempSync('oka_home_');
      addTearDown(() => home.delete(recursive: true));
      final legacy = Directory(p.join(home.path, '.oka', 'cache', 'maven'))
        ..createSync(recursive: true);
      File(p.join(legacy.path, 'artifact.jar')).writeAsStringSync('bytes');

      final root = MavenResolver.defaultCacheRoot(environment: envFor(home));

      expect(root, p.join(home.path, 'store', 'maven'));
      expect(legacy.existsSync(), isFalse,
          reason: 'legacy root is gone (renamed, not copied)');
      expect(
        File(p.join(root, 'artifact.jar')).readAsStringSync(),
        'bytes',
        reason: 'migrated content is preserved',
      );
    });

    test('prefers an existing store root without touching legacy', () {
      final home = Directory.systemTemp.createTempSync('oka_home_');
      addTearDown(() => home.delete(recursive: true));
      Directory(p.join(home.path, 'store', 'maven')).createSync(recursive: true);
      Directory(
        p.join(home.path, '.oka', 'cache', 'maven'),
      ).createSync(recursive: true);

      final root = MavenResolver.defaultCacheRoot(environment: envFor(home));

      expect(root, p.join(home.path, 'store', 'maven'));
      expect(
        Directory(p.join(home.path, '.oka', 'cache', 'maven')).existsSync(),
        isTrue,
      );
    });

    test('fresh machine resolves the store root', () {
      final home = Directory.systemTemp.createTempSync('oka_home_');
      addTearDown(() => home.delete(recursive: true));
      expect(
        MavenResolver.defaultCacheRoot(environment: envFor(home)),
        p.join(home.path, 'store', 'maven'),
      );
    });
  });

  group('warm-hit verification', () {
    test('a corrupted cached artifact re-downloads instead of shipping',
        () async {
      final home = Directory.systemTemp.createTempSync('oka_home_');
      addTearDown(() => home.delete(recursive: true));
      final resolver = MavenResolver(cacheRoot: p.join(home.path, 'maven'));
      const coord = MavenCoordinate(
        groupId: 'io.test',
        artifactId: 'sample',
        version: '1.0.0',
      );
      final original = List<int>.generate(300, (final i) => i % 256);

      await resolver.resolve(coord, fixtureBytes: original);
      // Warm hit works offline (fresh instance: no per-run memo).
      final warm = await MavenResolver(
        cacheRoot: p.join(home.path, 'maven'),
      ).resolve(coord);
      expect(warm.jarPath, isNotEmpty);

      // Corrupt the cache with same-size different bytes: the size-floor
      // heuristic alone would serve this; sha256 verification must not.
      await File(resolver.localPathFor(coord)).writeAsBytes(
        List<int>.generate(300, (final i) => (i * 7) % 256),
      );

      await expectLater(
        // Fresh instance (no memo), network disabled: the only correct
        // outcome is a loud failure (re-fetch impossible), never a silent
        // poisoned hit.
        MavenResolver(
          cacheRoot: p.join(home.path, 'maven'),
          allowNetwork: false,
        ).resolve(coord),
        throwsA(
          predicate(
            (final e) => e.toString().contains('network disabled'),
            'throws "network disabled"',
          ),
        ),
      );
    });

    test('intact cached artifacts keep serving offline', () async {
      final home = Directory.systemTemp.createTempSync('oka_home_');
      addTearDown(() => home.delete(recursive: true));
      final resolver = MavenResolver(cacheRoot: p.join(home.path, 'maven'));
      const coord = MavenCoordinate(
        groupId: 'io.test',
        artifactId: 'sample',
        version: '2.0.0',
      );
      await resolver.resolve(
        coord,
        fixtureBytes: List<int>.generate(300, (final i) => i % 256),
      );
      final warm = await MavenResolver(
        cacheRoot: p.join(home.path, 'maven'),
      ).resolve(coord);
      expect(
        File(warm.jarPath).readAsBytesSync(),
        List<int>.generate(300, (final i) => i % 256),
      );
    });
  });

  group('R8 store residency', () {
    test('store path derivation is stable and ContentKey-consistent', () {
      final env = envFor(temp);
      final key = r8StoreKey();
      expect(storeR8JarPath(environment: env), p.join(
        temp.path,
        'store',
        'r8',
        'r8',
        key.dirName,
        'any',
        'r8-${key.version}.jar',
      ));
    });

    test('findR8Jar prefers the store over the legacy tools dir', () async {
      final home = Directory(p.join(temp.path, 'home'))
        ..createSync(recursive: true);
      final env = envFor(home);
      final storePath = storeR8JarPath(environment: env);
      await File(storePath).parent.create(recursive: true);
      File(storePath).writeAsStringSync('store jar');
      final legacy = p.join(
        home.path,
        '.oka',
        'tools',
        'r8',
        'r8-$kR8Version.jar',
      );
      await File(legacy).parent.create(recursive: true);
      File(legacy).writeAsStringSync('legacy jar');

      final found = await findR8Jar(environment: env, home: home.path);
      expect(found, storePath);
    });

    test('findR8Jar falls back to the legacy tools copy', () async {
      final home = Directory(p.join(temp.path, 'home2'))
        ..createSync(recursive: true);
      final legacy = p.join(
        home.path,
        '.oka',
        'tools',
        'r8',
        'r8-$kR8Version.jar',
      );
      await File(legacy).parent.create(recursive: true);
      File(legacy).writeAsStringSync('legacy jar');
      expect(
        await findR8Jar(environment: envFor(home), home: home.path),
        legacy,
      );
    });
  });
}
