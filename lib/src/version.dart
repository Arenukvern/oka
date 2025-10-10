import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Gets the Oka version from pubspec.yaml
Future<String> getOkaVersion() async {
  try {
    // Find pubspec.yaml relative to the executable
    final executable = Platform.script.toFilePath();
    final packageRoot = _findPackageRoot(executable);

    if (packageRoot == null) {
      return 'unknown';
    }

    final pubspecFile = File(p.join(packageRoot, 'pubspec.yaml'));

    if (!await pubspecFile.exists()) {
      return 'unknown';
    }

    final content = await pubspecFile.readAsString();
    final yaml = loadYaml(content) as YamlMap;

    return yaml['version']?.toString() ?? 'unknown';
  } catch (e) {
    return 'unknown';
  }
}

/// Finds the package root by looking for pubspec.yaml
String? _findPackageRoot(String startPath) {
  var dir = File(startPath).parent;

  // Search up to 10 levels
  for (var i = 0; i < 10; i++) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      return dir.path;
    }

    final parent = dir.parent;
    if (parent.path == dir.path) {
      break; // Reached root
    }
    dir = parent;
  }

  return null;
}
