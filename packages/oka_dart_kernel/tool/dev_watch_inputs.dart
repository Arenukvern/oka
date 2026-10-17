import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:yaml/yaml.dart';

enum DevPackageWatchScope { project, local, all }

/// Resolved package roots, not directory guesses. Local packages are those
/// Pub classifies as path dependencies; hosted and SDK trees are opt-in.
List<String> resolveDevWatchFiles(
  String project, {
  DevPackageWatchScope packageScope = DevPackageWatchScope.local,
}) {
  final projectUri = Directory(project).absolute.uri;
  final roots = <String>{Directory.fromUri(projectUri.resolve('lib/')).path};
  final config = File.fromUri(
    projectUri.resolve('.dart_tool/package_config.json'),
  );
  if (packageScope != DevPackageWatchScope.project && config.existsSync()) {
    final lock = File.fromUri(projectUri.resolve('pubspec.lock'));
    final YamlMap? sources = lock.existsSync()
        ? ((loadYaml(lock.readAsStringSync()) as YamlMap?)?['packages']
              as YamlMap?)
        : null;
    final entries =
        (jsonDecode(config.readAsStringSync())
                as Map<String, dynamic>)['packages']
            as List;
    for (final entry in entries.cast<Map<String, dynamic>>()) {
      final name = entry['name'] as String;
      if (packageScope == DevPackageWatchScope.local &&
          (sources?[name] as YamlMap?)?['source'] != 'path') {
        continue;
      }
      final root = config.absolute.uri.resolve(entry['rootUri'] as String);
      if (root.scheme != 'file') continue;
      roots.add(
        Directory.fromUri(
          Directory.fromUri(root).absolute.uri.resolve('lib/'),
        ).path,
      );
    }
  }
  final files = <String>{};
  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    files.addAll(
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.absolute.path),
    );
  }
  try {
    files.addAll(declaredAssetFiles(project).map((p) => '$project/$p'));
    files.addAll(declaredShaderFiles(project).map((p) => '$project/$p'));
  } on AssetSpecException {
    // Preserve the existing Dart-only fallback for absent asset declarations.
  }
  return files.toList()..sort();
}
