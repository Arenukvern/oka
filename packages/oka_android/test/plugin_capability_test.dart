import 'dart:io';

import 'package:oka_android/src/build/dependency_cache.dart';
import 'package:oka_android/src/build/plugin_discovery.dart';
import 'package:oka_android/src/build/plugin_packager.dart';
import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _FixtureInspector implements PluginInputInspector {
  int inspections = 0;

  @override
  Future<PluginInputs> inspect(String pluginPath) async {
    inspections++;
    return const PluginInputs(
      javaSources: [],
      kotlinSources: [],
      gradleFiles: [],
      resourceDirs: [],
      manifestPaths: [],
      nativeLibsByAbi: {},
      needsNativeBuild: true,
    );
  }

  @override
  Future<String> writeBuildConfig({
    required String workDir,
    required String packageName,
    required bool debuggable,
  }) async => p.join(workDir, 'unused.java');
}

class _FixtureNativeBuilder implements NativeBuildService {
  final calls = <List<String>>[];

  @override
  Future<Map<String, String>> build({
    required String pluginPath,
    required String workDir,
    required List<String> abis,
  }) async {
    calls.add([...abis]);
    return {for (final abi in abis) abi: p.join(workDir, abi, 'libfixture.so')};
  }
}

void main() {
  test(
    'plugin Maven AAR resources and natives reach packaged payloads',
    () async {
      final temp = await Directory.systemTemp.createTemp('oka_plugin_aar_');
      addTearDown(() => temp.delete(recursive: true));
      final pluginRoot = Directory(p.join(temp.path, 'plugin'))..createSync();
      final android = Directory(p.join(pluginRoot.path, 'android'))
        ..createSync();
      File(p.join(android.path, 'build.gradle')).writeAsStringSync(
        "dependencies { implementation 'fixture:theme:1.0' }",
      );
      final dependencyRes = p.join(temp.path, 'theme', 'res');
      final nativePath = p.join(temp.path, 'theme', 'libfixture.so');
      final packager = PluginPackager(
        dependencyCache: _AarCache(temp.path, dependencyRes, nativePath),
        sdkLocator: SdkLocator(androidSdkPath: p.join(temp.path, 'sdk')),
        allowNetwork: false,
      );
      final result = await packager.packageOne(
        DiscoveredPlugin(
          name: 'theme_fixture',
          path: pluginRoot.path,
          hasAndroid: true,
        ),
        workDir: p.join(temp.path, 'work'),
        abis: const ['arm64-v8a'],
      );
      expect(result.packable, isTrue);
      expect(result.resDirs, contains(dependencyRes));
      expect(result.nativeLibsByAbi['arm64-v8a'], contains(nativePath));
    },
  );
  test(
    'packager delegates inspection and native building through constructors',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'oka_plugin_capability_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final pluginRoot = await Directory(p.join(temp.path, 'plugin')).create();
      final inspector = _FixtureInspector();
      final nativeBuilder = _FixtureNativeBuilder();
      final packager = PluginPackager(
        dependencyCache: DependencyCache(
          cacheRoot: p.join(temp.path, 'maven'),
          allowNetwork: false,
        ),
        sdkLocator: SdkLocator(androidSdkPath: p.join(temp.path, 'sdk')),
        allowNetwork: false,
        inputInspector: inspector,
        nativeBuildService: nativeBuilder,
      );

      final result = await packager.packageOne(
        DiscoveredPlugin(
          name: 'native_fixture',
          path: pluginRoot.path,
          hasAndroid: true,
        ),
        workDir: p.join(temp.path, 'work'),
        abis: const ['x86_64', 'arm64-v8a'],
      );

      expect(result.packable, isTrue);
      expect(inspector.inspections, 1);
      expect(nativeBuilder.calls.single, ['x86_64', 'arm64-v8a']);
      expect(result.nativeLibsByAbi.keys, containsAll(['x86_64', 'arm64-v8a']));
    },
  );
}

class _AarCache extends DependencyCache {
  _AarCache(String root, this.resourcePath, this.nativePath)
    : super(cacheRoot: root, allowNetwork: false);
  final String resourcePath;
  final String nativePath;

  @override
  Future<List<ResolvedJar>> resolveWithTransitives(
    List<MavenCoordinate> roots, {
    List<String> extraRepos = const [],
    int maxDepth = 2,
    int maxArtifacts = 250,
    void Function(MavenCoordinate coord, Object error)? onFailure,
  }) async => [
    ResolvedJar(
      coordinate: roots.first,
      jarPath: p.join(cacheRoot, 'classes.jar'),
      resDirs: [resourcePath],
      nativeLibsByAbi: {
        'arm64-v8a': [nativePath],
      },
    ),
  ];
}
