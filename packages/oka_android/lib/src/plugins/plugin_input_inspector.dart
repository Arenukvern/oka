import 'dart:io';

import 'package:path/path.dart' as p;

class PluginInputs {
  const PluginInputs({
    required this.javaSources,
    required this.kotlinSources,
    required this.gradleFiles,
    required this.resourceDirs,
    required this.manifestPaths,
    required this.nativeLibsByAbi,
    required this.needsNativeBuild,
  });

  final List<String> javaSources;
  final List<String> kotlinSources;
  final List<String> gradleFiles;
  final List<String> resourceDirs;
  final List<String> manifestPaths;
  final Map<String, List<String>> nativeLibsByAbi;
  final bool needsNativeBuild;
}

abstract interface class PluginInputInspector {
  Future<PluginInputs> inspect(String pluginPath);

  Future<String> writeBuildConfig({
    required String workDir,
    required String packageName,
    required bool debuggable,
  });
}

class FilePluginInputInspector implements PluginInputInspector {
  const FilePluginInputInspector();

  @override
  Future<PluginInputs> inspect(String pluginPath) async {
    final java = await _findSources(pluginPath, '.java');
    final kotlin = await _findSources(pluginPath, '.kt');
    final gradle = await _findGradleFiles(pluginPath);
    final resources = <String>[];
    final resourceDir = p.join(pluginPath, 'android', 'src', 'main', 'res');
    if (await Directory(resourceDir).exists()) resources.add(resourceDir);
    final manifests = <String>[];
    final manifest = p.join(
      pluginPath,
      'android',
      'src',
      'main',
      'AndroidManifest.xml',
    );
    if (await File(manifest).exists()) manifests.add(manifest);
    final natives = await _prebuiltNatives(pluginPath);
    var gradleNeedsNative = false;
    for (final path in gradle) {
      final source = await File(path).readAsString();
      if (source.contains('externalNativeBuild') || source.contains('cmake')) {
        gradleNeedsNative = true;
      }
    }
    return PluginInputs(
      javaSources: java,
      kotlinSources: kotlin,
      gradleFiles: gradle,
      resourceDirs: resources,
      manifestPaths: manifests,
      nativeLibsByAbi: natives,
      needsNativeBuild:
          await File(p.join(pluginPath, 'src', 'CMakeLists.txt')).exists() ||
          gradleNeedsNative,
    );
  }

  @override
  Future<String> writeBuildConfig({
    required String workDir,
    required String packageName,
    required bool debuggable,
  }) async {
    final path = p.join(
      workDir,
      'gen',
      packageName.replaceAll('.', '/'),
      'BuildConfig.java',
    );
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString('''
package $packageName;

public final class BuildConfig {
  public static final boolean DEBUG = $debuggable;
  public static final String LIBRARY_PACKAGE_NAME = "$packageName";
  public static final String BUILD_TYPE = "${debuggable ? 'debug' : 'release'}";
  private BuildConfig() {}
}
''');
    return path;
  }

  Future<List<String>> _findSources(String pluginPath, String extension) async {
    final files = <String>{};
    for (final root in [
      p.join(pluginPath, 'android', 'src', 'main'),
      p.join(pluginPath, 'java', 'src', 'main'),
      p.join(pluginPath, 'android'),
    ]) {
      final directory = Directory(root);
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File &&
            entry.path.endsWith(extension) &&
            !_isTestPath(entry.path)) {
          files.add(entry.path);
        }
      }
    }
    final output = files.toList()..sort();
    return output;
  }

  Future<List<String>> _findGradleFiles(String pluginPath) async {
    final output = <String>[];
    for (final candidate in [
      p.join(pluginPath, 'android', 'build.gradle'),
      p.join(pluginPath, 'android', 'build.gradle.kts'),
    ]) {
      if (await File(candidate).exists()) output.add(candidate);
    }
    return output;
  }

  Future<Map<String, List<String>>> _prebuiltNatives(String pluginPath) async {
    final output = <String, List<String>>{};
    for (final root in [
      p.join(pluginPath, 'android', 'src', 'main', 'jniLibs'),
      p.join(pluginPath, 'android', 'libs'),
      p.join(pluginPath, 'android', 'src', 'main', 'libs'),
    ]) {
      final directory = Directory(root);
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File || !entry.path.endsWith('.so')) continue;
        final parts = p.split(entry.path);
        if (parts.length < 2) continue;
        final abi = parts[parts.length - 2];
        if (const ['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'].contains(abi)) {
          output.putIfAbsent(abi, () => []).add(entry.path);
        }
      }
    }
    for (final paths in output.values) {
      paths.sort();
    }
    return output;
  }

  bool _isTestPath(String path) {
    final normalized = path.replaceAll(r'\', '/');
    return normalized.contains('/test/') ||
        normalized.contains('/androidTest/') ||
        normalized.contains('/src/test/');
  }
}
