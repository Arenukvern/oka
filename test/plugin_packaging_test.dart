import 'package:oka_core/src/config/maven_coordinate.dart';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/dependency_cache.dart';
import 'package:oka_android/src/build/host_codegen.dart';
import 'package:oka_android/src/build/plugin_discovery.dart';
import 'package:oka_android/src/build/plugin_packager.dart';
import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PluginPackager multi-plugin fixtures', () {
    late Directory tmp;
    late DependencyCache cache;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_plugin_pkg_');
      cache = DependencyCache(
        cacheRoot: p.join(tmp.path, 'maven'),
        allowNetwork: false,
        verbose: false,
      );
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<String> makeJavaPlugin({
      required String name,
      required String packageName,
      required String className,
    }) async {
      final root = p.join(tmp.path, name);
      final pkgPath = packageName.replaceAll('.', '/');
      final srcDir = p.join(root, 'android', 'src', 'main', 'java', pkgPath);
      await Directory(srcDir).create(recursive: true);
      await File(p.join(srcDir, '$className.java')).writeAsString('''
package $packageName;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
public class $className implements FlutterPlugin {
  @Override public void onAttachedToEngine(FlutterPluginBinding b) {}
  @Override public void onDetachedFromEngine(FlutterPluginBinding b) {}
}
''');
      await File(p.join(root, 'android', 'build.gradle')).writeAsString('''
dependencies {
    implementation 'androidx.annotation:annotation:1.9.1'
}
''');
      // Pre-seed annotation jar via fixture
      await cache.resolve(
        const MavenCoordinate(
          groupId: 'androidx.annotation',
          artifactId: 'annotation-jvm',
          version: '1.9.1',
          packaging: 'jar',
        ),
        fixtureBytes: minimalJarBytes(),
      );
      // Also seed the exact coord from gradle (annotation not annotation-jvm)
      await cache.resolve(
        const MavenCoordinate(
          groupId: 'androidx.annotation',
          artifactId: 'annotation',
          version: '1.9.1',
          packaging: 'jar',
        ),
        fixtureBytes: minimalJarBytes(),
      );
      await File(p.join(root, 'pubspec.yaml')).writeAsString('''
name: $name
flutter:
  plugin:
    platforms:
      android:
        package: $packageName
        pluginClass: $className
''');
      return root;
    }

    test(
      'packages two plugins and builds registrant with both classes',
      () async {
        final p1 = await makeJavaPlugin(
          name: 'alpha_plugin',
          packageName: 'com.example.alpha',
          className: 'AlphaPlugin',
        );
        final p2 = await makeJavaPlugin(
          name: 'beta_plugin',
          packageName: 'com.example.beta',
          className: 'BetaPlugin',
        );

        final discovery = PluginDiscoveryResult(
          plugins: [
            DiscoveredPlugin(
              name: 'alpha_plugin',
              path: p1,
              hasAndroid: true,
              androidPackage: 'com.example.alpha',
              pluginClass: 'AlphaPlugin',
            ),
            DiscoveredPlugin(
              name: 'beta_plugin',
              path: p2,
              hasAndroid: true,
              androidPackage: 'com.example.beta',
              pluginClass: 'BetaPlugin',
            ),
          ],
          unsupported: const [],
        );

        final locator = SdkLocator(androidSdkPath: p.join(tmp.path, 'no_sdk'));
        // packaging sources does not need real SDK
        final packager = PluginPackager(
          dependencyCache: cache,
          sdkLocator: locator,
          verbose: false,
          allowNetwork: false,
        );

        final result = await packager.packageAll(
          discovery,
          buildDir: p.join(tmp.path, 'build'),
          abis: ['arm64-v8a'],
        );

        expect(result.failed, isEmpty);
        expect(result.allJavaSources.length, greaterThanOrEqualTo(2));
        expect(
          result.registrations.map((r) => r.className),
          containsAll([
            'com.example.alpha.AlphaPlugin',
            'com.example.beta.BetaPlugin',
          ]),
        );

        final registrant = generatePluginRegistrantJava(result.registrations);
        expect(registrant, contains('AlphaPlugin'));
        expect(registrant, contains('BetaPlugin'));
        expect(registrant, isNot(contains('No plugins registered')));
      },
    );

    test('AAR extract path contributes jar dep', () async {
      final root = p.join(tmp.path, 'aar_plugin');
      final srcDir = p.join(
        root,
        'android',
        'src',
        'main',
        'java',
        'com',
        'example',
      );
      await Directory(srcDir).create(recursive: true);
      await File(p.join(srcDir, 'AarPlugin.java')).writeAsString('''
package com.example;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
public class AarPlugin implements FlutterPlugin {
  @Override public void onAttachedToEngine(FlutterPluginBinding b) {}
  @Override public void onDetachedFromEngine(FlutterPluginBinding b) {}
}
''');
      await File(p.join(root, 'android', 'build.gradle')).writeAsString('''
dependencies {
    implementation("androidx.core:core:1.13.1")
}
''');
      // Seed non-empty AAR classes jar so resolveWithTransitives keeps it
      final classes = List<int>.from(minimalJarBytes());
      while (classes.length < 300) {
        classes.addAll(minimalJarBytes());
      }
      final aar = Archive();
      aar.addFile(ArchiveFile('classes.jar', classes.length, classes));
      final aarBytes = ZipEncoder().encodeBytes(aar);
      await cache.resolve(
        const MavenCoordinate(
          groupId: 'androidx.core',
          artifactId: 'core',
          version: '1.13.1',
          packaging: 'aar',
        ),
        fixtureBytes: aarBytes,
      );
      // Bootstrap deps also required offline
      await cache.resolve(
        const MavenCoordinate(
          groupId: 'androidx.annotation',
          artifactId: 'annotation-jvm',
          version: '1.9.1',
          packaging: 'jar',
        ),
        fixtureBytes: classes,
      );
      await cache.resolve(
        const MavenCoordinate(
          groupId: 'org.jetbrains',
          artifactId: 'annotations',
          version: '24.1.0',
          packaging: 'jar',
        ),
        fixtureBytes: classes,
      );

      final packager = PluginPackager(
        dependencyCache: cache,
        sdkLocator: SdkLocator(androidSdkPath: p.join(tmp.path, 'x')),
        allowNetwork: false,
      );
      final one = await packager.packageOne(
        DiscoveredPlugin(
          name: 'aar_plugin',
          path: root,
          hasAndroid: true,
          androidPackage: 'com.example',
          pluginClass: 'AarPlugin',
        ),
        workDir: p.join(tmp.path, 'work'),
        abis: ['arm64-v8a'],
      );
      expect(one.packable, isTrue);
      expect(one.jarDeps, isNotEmpty);
      expect(one.javaSources, isNotEmpty);
    });

    test(
      'strict packaging fails clearly when pluginClass has no sources',
      () async {
        final root = p.join(tmp.path, 'broken');
        await Directory(p.join(root, 'android')).create(recursive: true);
        await File(p.join(root, 'android', 'build.gradle')).writeAsString('');
        final packager = PluginPackager(
          dependencyCache: cache,
          sdkLocator: SdkLocator(androidSdkPath: p.join(tmp.path, 'x')),
          allowNetwork: false,
        );
        final broken = await packager.packageOne(
          DiscoveredPlugin(
            name: 'broken',
            path: root,
            hasAndroid: true,
            androidPackage: 'com.example',
            pluginClass: 'Missing',
          ),
          workDir: p.join(tmp.path, 'w2'),
          abis: ['arm64-v8a'],
        );
        expect(broken.packable, isFalse);
        expect(broken.failureReason, contains('no Java/Kotlin sources'));
      },
    );
  });

  test('default build does not empty registrant (source contract)', () async {
    final src = await File(
      p.join('packages', 'oka_android', 'lib', 'src', 'pipeline', 'steps', 'host_steps.dart'),
    ).readAsString();
    expect(src, contains('PluginPackagingStep'));
    expect(src, contains('registrations'));
    expect(
      src,
      isNot(contains('Soft packaging: omitting all plugin registrations')),
    );
  });
}
