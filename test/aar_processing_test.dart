import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/dependency_cache.dart';
import 'package:oka_core/src/config/maven_coordinate.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a minimal in-memory AAR (zip) with the given entries.
List<int> buildTestAar(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encodeBytes(archive);
}

// Minimal valid classes.jar content (a zip with one file).
final _classesJarBytes = () {
  final jar = Archive();
  jar.addFile(ArchiveFile('com/example/Foo.class', 4, [1, 2, 3, 4]));
  return ZipEncoder().encodeBytes(jar);
}();

void main() {
  group('extractAarPayload', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_aar_');
    });

    tearDown(() => tmp.delete(recursive: true));

    test('extracts jni natives per abi', () async {
      final aar = buildTestAar({
        'classes.jar': _classesJarBytes,
        'jni/arm64-v8a/libfoo.so': [1, 2, 3],
        'jni/x86_64/libfoo.so': [4, 5],
        'AndroidManifest.xml': '<manifest/>'.codeUnits,
      });
      final dest = p.join(tmp.path, 'payload');
      final payload = await extractAarPayload(aar, dest);

      expect(
        payload.nativeLibsByAbi.keys,
        containsAll(['arm64-v8a', 'x86_64']),
      );
      expect(
        File(p.join(dest, 'jni', 'arm64-v8a', 'libfoo.so')).readAsBytesSync(),
        [1, 2, 3],
      );
      expect(payload.resDirs, isEmpty);
    });

    test('extracts res xml tree', () async {
      final aar = buildTestAar({
        'classes.jar': _classesJarBytes,
        'res/values/values.xml': '<resources/>'.codeUnits,
      });
      final dest = p.join(tmp.path, 'payload');
      final payload = await extractAarPayload(aar, dest);

      expect(payload.resDirs, hasLength(1));
      expect(
        File(
          p.join(payload.resDirs.first, 'values', 'values.xml'),
        ).existsSync(),
        isTrue,
      );
      expect(payload.nativeLibsByAbi, isEmpty);
    });

    test('ignores non-xml res and non-jni so files', () async {
      final aar = buildTestAar({
        'classes.jar': _classesJarBytes,
        'res/drawable/icon.png': [9, 9],
        'libs/other.so': [7], // libs/, not jni/
      });
      final payload = await extractAarPayload(aar, p.join(tmp.path, 'p'));

      expect(payload.nativeLibsByAbi, isEmpty);
      expect(payload.resDirs, isEmpty);
    });

    test('aar with no payload yields empty result', () async {
      final aar = buildTestAar({'classes.jar': _classesJarBytes});
      final payload = await extractAarPayload(aar, p.join(tmp.path, 'p'));

      expect(payload.nativeLibsByAbi, isEmpty);
      expect(payload.resDirs, isEmpty);
    });
  });

  group('DependencyCache.resolve with AAR payload', () {
    test('resolved aar carries natives and res dirs', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_aar_cache_');
      addTearDown(() => tmp.delete(recursive: true));

      final aar = buildTestAar({
        'classes.jar': _classesJarBytes,
        'jni/arm64-v8a/libbar.so': [1],
        'res/values/values.xml': '<resources/>'.codeUnits,
      });
      final cache = DependencyCache(cacheRoot: tmp.path, allowNetwork: false);
      const coord = MavenCoordinate(
        groupId: 'com.example',
        artifactId: 'native-lib',
        version: '1.0.0',
        packaging: 'aar',
      );

      final resolved = await cache.resolve(coord, fixtureBytes: aar);
      expect(resolved.nativeLibsByAbi['arm64-v8a'], hasLength(1));
      expect(resolved.resDirs, hasLength(1));
      // classes.jar extracted next to payload
      expect(File(resolved.jarPath).lengthSync(), greaterThan(0));
    });

    test('jar packaging resolves without payload fields', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_jar_cache_');
      addTearDown(() => tmp.delete(recursive: true));

      final cache = DependencyCache(cacheRoot: tmp.path, allowNetwork: false);
      const coord = MavenCoordinate(
        groupId: 'com.example',
        artifactId: 'plain',
        version: '1.0.0',
      );

      final resolved = await cache.resolve(coord, fixtureBytes: [1, 2, 3, 4]);
      expect(resolved.nativeLibsByAbi, isEmpty);
      expect(resolved.resDirs, isEmpty);
    });
  });
}
