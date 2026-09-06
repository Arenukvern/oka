import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Minimal plugin dir exercising the mobile_scanner fixture gradle content.
Future<Directory> _makePlugin(
  Directory tmp, {
  required String name,
  bool withKotlin = false,
}) async {
  final pluginDir = Directory(p.join(tmp.path, name));
  final androidDir = Directory(p.join(pluginDir.path, 'android', 'src', 'main'));
  await androidDir.create(recursive: true);
  File(p.join(pluginDir.path, 'android', 'build.gradle')).writeAsStringSync(
    File('test/fixtures/gradle/mobile_scanner.gradle').readAsStringSync(),
  );
  if (withKotlin) {
    Directory(p.join(androidDir.path, 'kotlin')).createSync(recursive: true);
    File(
      p.join(androidDir.path, 'kotlin', 'Foo.kt'),
    ).writeAsStringSync('class Foo');
  }
  return pluginDir;
}

DiscoveredPlugin _plugin(Directory dir) => DiscoveredPlugin(
      name: 'mobile_scanner',
      path: dir.path,
      hasAndroid: true,
      pluginClass: 'MobileScannerPlugin',
      androidPackage: 'dev.steenbakker.mobile_scanner',
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('oka-depplan-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('collectDeclaredDeps (shared with packaging)', () {
    test('collects deduped gradle coords; no kotlin bootstrap without kotlin',
        () async {
      final pluginDir = await _makePlugin(tmp, name: 'p_');
      final packager = PluginPackager(
        dependencyCache: DependencyCache(cacheRoot: p.join(tmp.path, 'cache')),
        sdkLocator: SdkLocator(),
      );
      final declared = await packager.collectDeclaredDeps(
        _plugin(pluginDir),
        hasKotlinSources: false,
      );

      final coords = declared.rootCoords.map((c) => c.cacheKey).toSet();
      // Conditional dedup applied: only the gradle-default (first) ML Kit
      // variant survives.
      expect(
        coords,
        contains('com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1:aar'),
      );
      expect(
        coords.any((c) => c.startsWith('com.google.mlkit:barcode-scanning')),
        isFalse,
      );
      expect(
        coords,
        contains('androidx.camera:camera-lifecycle:1.6.1:aar'),
      );
      // Kotlin bootstrap NOT gated in without kotlin sources.
      expect(
        coords.any((c) => c.startsWith('org.jetbrains.kotlin:kotlin-stdlib:')),
        isFalse,
      );
      // AndroidX bootstrap always present.
      expect(
        coords,
        contains('androidx.annotation:annotation-jvm:1.9.1:jar'),
      );
    });

    test('kotlin bootstrap gated on kotlin sources', () async {
      final pluginDir = await _makePlugin(tmp, name: 'p_kt', withKotlin: true);
      final packager = PluginPackager(
        dependencyCache: DependencyCache(cacheRoot: p.join(tmp.path, 'cache')),
        sdkLocator: SdkLocator(),
      );
      final declared = await packager.collectDeclaredDeps(
        _plugin(pluginDir),
        hasKotlinSources: true,
      );
      final coords = declared.rootCoords.map((c) => c.cacheKey).toSet();
      expect(
        coords,
        contains('org.jetbrains.kotlin:kotlin-stdlib:2.0.21:jar'),
      );
    });

    test('hasKotlinSources detects plugin kotlin trees', () async {
      final plain = await _makePlugin(tmp, name: 'plain');
      final withKt = await _makePlugin(tmp, name: 'withkt', withKotlin: true);
      final packager = PluginPackager(
        dependencyCache: DependencyCache(cacheRoot: p.join(tmp.path, 'cache')),
        sdkLocator: SdkLocator(),
      );
      expect(await packager.hasKotlinSources(_plugin(plain)), isFalse);
      expect(await packager.hasKotlinSources(_plugin(withKt)), isTrue);
    });
  });

  group('buildDependencyPlan', () {
    DependencyCache offlineCache() => DependencyCache(
          cacheRoot: p.join(tmp.path, 'cache'),
          allowNetwork: false,
        );

    test('cache-only: missing artifacts are non-fatal findings', () async {
      final pluginDir = await _makePlugin(tmp, name: 'p_');
      final cache = offlineCache();
      final report = await buildDependencyPlan(
        plugins: [_plugin(pluginDir)],
        packager: PluginPackager(dependencyCache: cache, sdkLocator: SdkLocator()),
        cache: cache,
        allowNetwork: false,
      );

      expect(report.cacheOnly, isTrue);
      expect(report.resolved, isEmpty);
      expect(report.hasFatal, isFalse);
      expect(report.findings, isNotEmpty);
      for (final f in report.findings) {
        expect(f.fatal, isFalse, reason: f.message);
        expect(f.message, contains('not in local maven cache'));
      }
      expect(report.summary(), contains('cache-only'));
      // flutter-embedding entry always composed.
      expect(
        report.entries.map((e) => e.source),
        contains('flutter-embedding'),
      );
    });

    test('offline cache hits resolve and are finding-free', () async {
      final pluginDir = await _makePlugin(tmp, name: 'p_');
      final cache = offlineCache();
      // Seed the androidx.annotation bootstrap root as a cache hit.
      const coord = MavenCoordinate(
        groupId: 'androidx.annotation',
        artifactId: 'annotation-jvm',
        version: '1.9.1',
      );
      final jar = File(cache.jarPathFor(coord));
      await jar.parent.create(recursive: true);
      await jar.writeAsBytes(List.filled(400, 7));

      final report = await buildDependencyPlan(
        plugins: [_plugin(pluginDir)],
        packager: PluginPackager(dependencyCache: cache, sdkLocator: SdkLocator()),
        cache: cache,
        allowNetwork: false,
      );

      expect(
        report.resolved.map((r) => r.coordinate.cacheKey),
        contains(coord.cacheKey),
      );
      expect(
        report.findings
            .where((f) => f.coordinate?.cacheKey == coord.cacheKey),
        isEmpty,
      );
    });

    test('malformed extra_deps is a fatal finding', () async {
      final cache = offlineCache();
      final report = await buildDependencyPlan(
        plugins: const [],
        extraDeps: ['not-a-coordinate'],
        packager: PluginPackager(dependencyCache: cache, sdkLocator: SdkLocator()),
        cache: cache,
        allowNetwork: false,
      );
      expect(report.hasFatal, isTrue);
      expect(
        report.findings.map((f) => f.message),
        contains(contains('malformed coordinate')),
      );
    });

    test('well-formed extra_deps join the plan', () async {
      final cache = offlineCache();
      final report = await buildDependencyPlan(
        plugins: const [],
        extraDeps: ['com.squareup.okhttp3:okhttp:4.12.0'],
        packager: PluginPackager(dependencyCache: cache, sdkLocator: SdkLocator()),
        cache: cache,
        allowNetwork: false,
      );
      final entry =
          report.entries.singleWhere((e) => e.source == 'pipeline.extra_deps');
      expect(entry.rootCoords.single.cacheKey,
          'com.squareup.okhttp3:okhttp:4.12.0:jar');
      // Offline: reported as cache miss, not a hard failure.
      expect(report.hasFatal, isFalse);
    });

    test('failure findings attribute back to their source entry', () async {
      final pluginDir = await _makePlugin(tmp, name: 'p_');
      final cache = offlineCache();
      final report = await buildDependencyPlan(
        plugins: [_plugin(pluginDir)],
        packager: PluginPackager(dependencyCache: cache, sdkLocator: SdkLocator()),
        cache: cache,
        allowNetwork: false,
      );
      final mlkitMiss = report.findings.firstWhere(
        (f) =>
            f.coordinate?.cacheKey ==
            'com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1:aar',
      );
      expect(mlkitMiss.source, 'mobile_scanner');
    });
  });
}
