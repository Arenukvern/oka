import 'dart:convert';
import 'dart:io';

import 'package:oka_android/src/maven_resolver.dart';
import 'package:test/test.dart';

/// Fixture: a trimmed Gradle module metadata JSON modeled on
/// `androidx.camera:camera-camera2` — the motivating case where the POM
/// omits a runtime dependency (`kotlinx-atomicfu`) that only the `.module`
/// declares.
const _cameraLikeModule = '''
{
  "formatVersion": "1.1",
  "component": {"group": "androidx.camera", "module": "camera-camera2", "version": "1.6.1"},
  "variants": [
    {
      "name": "releaseVariantReleaseApiPublication",
      "attributes": {"org.gradle.category": "library"},
      "dependencies": [
        {"group": "org.jetbrains.kotlinx", "module": "kotlinx-coroutines-core", "version": {"requires": "1.9.0"}}
      ]
    },
    {
      "name": "releaseVariantReleaseRuntimePublication",
      "attributes": {"org.gradle.category": "library"},
      "dependencies": [
        {"group": "org.jetbrains.kotlinx", "module": "atomicfu", "version": {"requires": "0.28.0"}},
        {"group": "androidx.core", "module": "core"}
      ]
    },
    {
      "name": "iosArm64RuntimeElements-published",
      "dependencies": [
        {"group": "org.jetbrains.kotlinx", "module": "atomicfu-iosarm64", "version": {"requires": "0.28.0"}}
      ]
    },
    {
      "name": "releaseVariantReleaseApiPublicationSources",
      "dependencies": []
    }
  ]
}
''';

void main() {
  group('parseModuleRuntimeDependencies', () {
    test('extracts runtime deps from runtime variants only', () {
      final deps = parseModuleRuntimeDependencies(_cameraLikeModule);
      // atomicfu is declared ONLY in the runtime variant — the motivating
      // case. Api-variant deps (kotlinx-coroutines-core) are intentionally
      // excluded: the POM graph already covers compile-scope deps.
      expect(
        deps.map((d) => '${d.groupId}:${d.artifactId}:${d.version}'),
        contains('org.jetbrains.kotlinx:atomicfu:0.28.0'),
      );
      expect(
        deps.map((d) => d.artifactId),
        isNot(contains('kotlinx-coroutines-core')),
      );
    });

    test('skips non-Android/JVM platform and sources variants', () {
      final deps = parseModuleRuntimeDependencies(_cameraLikeModule);
      expect(
        deps.map((d) => d.artifactId),
        isNot(contains('atomicfu-iosarm64')),
      );
    });

    test('skips version-less entries managed elsewhere', () {
      final deps = parseModuleRuntimeDependencies(_cameraLikeModule);
      expect(deps.map((d) => d.artifactId), isNot(contains('core')));
    });

    test('prefers requires > prefers > strictly', () {
      final json = jsonEncode({
        'variants': [
          {
            'name': 'jvmRuntimeElements-published',
            'dependencies': [
              {
                'group': 'g',
                'module': 'a',
                'version': {'strictly': '1.0', 'prefers': '2.0', 'requires': '3.0'},
              },
            ],
          },
        ],
      });
      final deps = parseModuleRuntimeDependencies(json);
      expect(deps.single.version, '3.0');
    });

    test('returns empty for malformed JSON and missing variants', () {
      expect(parseModuleRuntimeDependencies('not json'), isEmpty);
      expect(parseModuleRuntimeDependencies('{}'), isEmpty);
      expect(parseModuleRuntimeDependencies('{"variants": "x"}'), isEmpty);
    });

    test('parses the real androidx.camera 1.6.1 module when cached', () {
      // Integration-flavored: exercises the exact file that motivated the
      // parser. Skipped when the artifact is not in the local maven cache
      // (offline-safe).
      final home = Platform.environment['HOME'] ?? '';
      final file = File(
        '$home/.oka/cache/maven/androidx/camera/camera-camera2/1.6.1/'
        'camera-camera2-1.6.1.module',
      );
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('skip: camera .module not cached');
        return;
      }
      final deps = parseModuleRuntimeDependencies(file.readAsStringSync());
      expect(
        deps.where((d) => d.artifactId == 'atomicfu'),
        isNotEmpty,
        reason: 'camera runtime must surface its atomicfu dependency',
      );
    });
  });
}
