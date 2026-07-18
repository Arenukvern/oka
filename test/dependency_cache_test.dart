import 'dart:io';

import 'package:oka/src/build/dependency_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('googleMavenUrl', () {
    test('builds google maven path', () {
      const c = MavenCoordinate(
        groupId: 'androidx.annotation',
        artifactId: 'annotation-jvm',
        version: '1.9.1',
        packaging: 'jar',
      );
      expect(
        googleMavenUrl(c),
        'https://maven.google.com/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar',
      );
    });
  });

  group('extractClassesJarFromAar', () {
    test('extracts classes.jar from minimal aar bytes', () {
      final aar = minimalAarBytes();
      final jar = extractClassesJarFromAar(aar);
      expect(jar.length, greaterThan(10));
      // JAR is a zip — starts with PK
      expect(jar[0], 0x50);
      expect(jar[1], 0x4b);
    });

    test('throws when classes.jar missing', () {
      final emptyZip = minimalJarBytes(); // not an AAR with classes.jar
      expect(() => extractClassesJarFromAar(emptyZip), throwsException);
    });
  });

  group('DependencyCache', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_deps_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('resolve jar from fixture without network', () async {
      final cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'maven'),
        allowNetwork: false,
      );
      const coord = MavenCoordinate(
        groupId: 'androidx.annotation',
        artifactId: 'annotation-jvm',
        version: '1.9.1',
        packaging: 'jar',
      );
      final resolved = await cache.resolve(
        coord,
        fixtureBytes: minimalJarBytes(),
      );
      expect(await File(resolved.jarPath).exists(), isTrue);
      expect(resolved.jarPath, endsWith('.jar'));
    });

    test('resolve aar extracts classes.jar', () async {
      final cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'maven'),
        allowNetwork: false,
      );
      const coord = MavenCoordinate(
        groupId: 'androidx.core',
        artifactId: 'core',
        version: '1.13.1',
        packaging: 'aar',
      );
      final resolved = await cache.resolve(
        coord,
        fixtureBytes: minimalAarBytes(),
      );
      expect(await File(resolved.jarPath).exists(), isTrue);
      expect(resolved.jarPath, contains('classes.jar'));
      // Second resolve hits cache
      final again = await cache.resolve(coord);
      expect(again.jarPath, resolved.jarPath);
    });

    test('resolveFlutterAndroidX with fixtures covers fixed set', () async {
      final cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'maven'),
        allowNetwork: false,
      );
      final fixtures = <String, List<int>>{};
      for (final c in flutterEmbeddingAndroidXDeps()) {
        fixtures[c.cacheKey] =
            c.packaging == 'aar' ? minimalAarBytes() : minimalJarBytes();
      }
      final jars = await cache.resolveFlutterAndroidX(fixtures: fixtures);
      expect(jars.length, flutterEmbeddingAndroidXDeps().length);
      for (final j in jars) {
        expect(await File(j.jarPath).exists(), isTrue);
      }
    });

    test('offline missing dep throws clearly', () async {
      final cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'empty'),
        allowNetwork: false,
      );
      const coord = MavenCoordinate(
        groupId: 'androidx.foo',
        artifactId: 'bar',
        version: '1.0.0',
      );
      expect(
        () => cache.resolve(coord),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('network disabled'),
        )),
      );
    });
  });

  test('flutterEmbeddingAndroidXDeps is non-empty fixed set', () {
    final deps = flutterEmbeddingAndroidXDeps();
    expect(deps, isNotEmpty);
    expect(deps.any((d) => d.artifactId.contains('annotation')), isTrue);
    expect(deps.any((d) => d.packaging == 'aar'), isTrue);
  });
}
