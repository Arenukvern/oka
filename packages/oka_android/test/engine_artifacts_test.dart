import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/apk_layout.dart';
import 'package:oka_android/src/build/engine_artifacts.dart';
import 'package:oka_android/src/build_cache.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Engine-variant pairing (release splash-hang regression, 2026-09-27): a
/// missing release `flutter.jar` used to fall back silently to the DEBUG
/// jar, shipping release APKs whose JIT debug engine could never run the
/// AOT snapshot — boot to splash, zero frames, Dart `main()` never runs.
void main() {
  group('engine variant mapping', () {
    test('mode → variant suffix', () {
      expect(engineVariantForMode(BuildMode.debug), '');
      expect(engineVariantForMode(BuildMode.profile), '-profile');
      expect(engineVariantForMode(BuildMode.release), '-release');
    });

    test('variant → engine cache dir per ABI', () {
      expect(
        engineArtifactDirForVariant('arm64-v8a', variant: '-release'),
        'android-arm64-release',
      );
      expect(
        engineArtifactDirForVariant('android-arm64', variant: '-profile'),
        'android-arm64-profile',
      );
      expect(
        engineArtifactDirForVariant('arm64-v8a', variant: ''),
        'android-arm64',
      );
      expect(
        () => engineArtifactDirForVariant('arm64-v8a', variant: '-debug'),
        throwsArgumentError,
      );
    });
  });

  group('EngineArtifacts', () {
    late Directory sdk;
    late EngineArtifacts engine;

    /// Builds `<sdk>/bin/cache/artifacts/engine` with jars for the given
    /// variants; each jar carries a distinguishable libflutter.so payload.
    Future<void> buildSdk(final Map<String, String> variants) async {
      final engineRoot = p.join(
        sdk.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
      );
      for (final entry in variants.entries) {
        final dir = Directory(p.join(engineRoot, entry.key))..createSync(recursive: true);
        final archive = Archive();
        archive.addFile(
          ArchiveFile(
            'lib/arm64-v8a/libflutter.so',
            entry.value.length,
            entry.value.codeUnits,
          ),
        );
        File(p.join(dir.path, 'flutter.jar')).writeAsBytesSync(
          ZipEncoder().encodeBytes(archive),
        );
      }
    }

    setUp(() async {
      sdk = await Directory.systemTemp.createTemp('oka_engine_fixture_');
      addTearDown(() => sdk.delete(recursive: true));
      engine = EngineArtifacts(sdk.path);
    });

    test('findFlutterJar resolves the exact variant jar', () async {
      await buildSdk({
        'android-arm64': 'debug-engine',
        'android-arm64-release': 'release-engine',
      });
      expect(
        await engine.findFlutterJar('arm64-v8a', variant: '-release'),
        p.join(
          sdk.path,
          'bin/cache/artifacts/engine/android-arm64-release/flutter.jar',
        ),
      );
      expect(
        await engine.findFlutterJar('arm64-v8a', variant: ''),
        p.join(sdk.path, 'bin/cache/artifacts/engine/android-arm64/flutter.jar'),
      );
    });

    test(
      'findFlutterJar returns null for a missing variant — never the debug jar',
      () async {
        // Only the debug jar exists (fresh `flutter assemble`-only cache).
        await buildSdk({'android-arm64': 'debug-engine'});
        expect(
          await engine.findFlutterJar('arm64-v8a', variant: '-release'),
          isNull,
        );
      },
    );

    test('extractLibflutterFromJar extracts the ABI libflutter.so', () async {
      await buildSdk({'android-arm64-release': 'release-engine'});
      final jar = await engine.findFlutterJar('arm64-v8a', variant: '-release');
      final dest = p.join(sdk.path, 'out', 'libflutter.so');
      await engine.extractLibflutterFromJar(
        flutterJar: jar!,
        abi: 'arm64-v8a',
        destSoPath: dest,
      );
      expect(File(dest).readAsStringSync(), 'release-engine');
    });

    test('ensureEngineJars is a no-op when every jar is present', () async {
      await buildSdk({'android-arm64-release': 'release-engine'});
      var precacheCalled = false;
      final jars = await engine.ensureEngineJars(
        abis: ['arm64-v8a'],
        variant: '-release',
        runProcess: (final exe, final args, {final workingDirectory}) {
          precacheCalled = true;
          throw StateError('precache must not run');
        },
      );
      expect(precacheCalled, isFalse);
      expect(jars['arm64-v8a'], isNotNull);
    });

    test(
      'ensureEngineJars runs flutter precache --android once, then resolves',
      () async {
        final releaseDir = p.join(
          sdk.path,
          'bin/cache/artifacts/engine/android-arm64-release',
        );
        final invocations = <List<String>>[];
        final jars = await engine.ensureEngineJars(
          abis: ['arm64-v8a'],
          variant: '-release',
          runProcess: (final exe, final args, {final workingDirectory}) async {
            invocations.add([exe, ...args]);
            // Simulate the precache populating the release jar.
            Directory(releaseDir).createSync(recursive: true);
            final archive = Archive()
              ..addFile(
                ArchiveFile(
                  'lib/arm64-v8a/libflutter.so',
                  14,
                  'release-engine'.codeUnits,
                ),
              );
            File(p.join(releaseDir, 'flutter.jar'))
                .writeAsBytesSync(ZipEncoder().encodeBytes(archive));
            return ProcessResult(0, 0, '', '');
          },
        );
        expect(invocations, [
          ['flutter', 'precache', '--android'],
        ]);
        expect(jars['arm64-v8a'], contains('android-arm64-release'));
      },
    );

    test(
      'ensureEngineJars throws instead of substituting another variant',
      () async {
        await buildSdk({'android-arm64': 'debug-engine'});
        await expectLater(
          engine.ensureEngineJars(
            abis: ['arm64-v8a'],
            variant: '-release',
            runProcess: (final exe, final args, {final workingDirectory}) =>
                Future.value(ProcessResult(0, 0, '', '')),
          ),
          throwsA(
            predicate(
              (final e) =>
                  e is Exception &&
                  e.toString().contains('precache') &&
                  e.toString().contains('splash'),
            ),
          ),
        );
      },
    );

    test(
      'ensureEngineJars surfaces precache failure instead of proceeding',
      () async {
        await expectLater(
          engine.ensureEngineJars(
            abis: ['arm64-v8a'],
            variant: '-release',
            runProcess: (final exe, final args, {final workingDirectory}) =>
              Future.value(ProcessResult(0, 1, '', 'offline')),
          ),
          throwsA(
            predicate(
              (final e) => e is Exception && e.toString().contains('offline'),
            ),
          ),
        );
      },
    );
  });

  group('path-dependency fingerprint inputs', () {
    late Directory temp;
    late Directory project;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oka_fp_fixture_');
      addTearDown(() => temp.delete(recursive: true));
      project = Directory(p.join(temp.path, 'apps', 'app'))
        ..createSync(recursive: true);
    });

    /// Pub-workspace layout: package_config at the workspace root, path dep
    /// referenced relatively, hosted dep under .pub-cache (excluded).
    void writePackageConfig(final String json) {
      Directory(p.join(temp.path, '.dart_tool')).createSync(recursive: true);
      File(
        p.join(temp.path, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync(json);
    }

    test('pathDependencyRoots resolves relative rootUris, skips pub-cache',
        () {
      writePackageConfig('''
{
  "configVersion": 2,
  "packages": [
    {"name": "my_dep", "rootUri": "../packages/my_dep"},
    {"name": "hosted", "rootUri": "file:///Users/x/.pub-cache/hosted/pub.dev/foo-1.0.0"},
    {"name": "sdk_pkg", "rootUri": "file:///flutter/bin/cache/pkg/sky_engine"}
  ]
}
''');
      final config = packageConfigFor(project.path);
      expect(config, isNotNull);
      final roots = pathDependencyRoots(
        config!.readAsStringSync(),
        configDir: p.dirname(config.path),
      );
      expect(roots, [
        p.normalize(p.join(temp.path, 'packages', 'my_dep')),
      ]);
    });

    test('pathDependencyInputs covers path-dep pubspec + lib sources',
        () {
      writePackageConfig('''
{"configVersion": 2,
 "packages": [{"name": "my_dep", "rootUri": "../packages/my_dep"}]}
''');
      final depLib = Directory(p.join(temp.path, 'packages', 'my_dep', 'lib'))
        ..createSync(recursive: true);
      File(p.join(depLib.path, 'core.dart')).writeAsStringSync('void f() {}');
      File(
        p.join(temp.path, 'packages', 'my_dep', 'pubspec.yaml'),
      ).writeAsStringSync('name: my_dep\n');

      final inputs = pathDependencyInputs(project.path);
      expect(
        inputs.any((final f) => f.endsWith('my_dep/pubspec.yaml')),
        isTrue,
      );
      expect(inputs.any((final f) => f.endsWith('my_dep/lib/core.dart')), isTrue);
    });

    test('fingerprint changes when a path-dep source changes', () async {
      writePackageConfig('''
{"configVersion": 2,
 "packages": [{"name": "my_dep", "rootUri": "../packages/my_dep"}]}
''');
      final depLib = Directory(p.join(temp.path, 'packages', 'my_dep', 'lib'))
        ..createSync(recursive: true);
      final source = File(p.join(depLib.path, 'core.dart'))
        ..writeAsStringSync('void f() {}');
      final before = await fingerprintInputs(
        pathDependencyInputs(project.path),
      );
      source.writeAsStringSync('void g() {}');
      final after = await fingerprintInputs(
        pathDependencyInputs(project.path),
      );
      expect(after, isNot(before));
    });

    test('no package_config anywhere → no path-dep inputs', () {
      expect(pathDependencyInputs(project.path), isEmpty);
      expect(packageConfigFor(project.path), isNull);
    });
  });
}
