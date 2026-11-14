import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Anchor file checked in at the oka monorepo root.
const okaWorkspaceRootAnchor = 'tool/release/train.dart';

/// Resolves the oka monorepo root by walking parents toward `/`.
///
/// When [start] is omitted, walks from the `oka_core` package root in
/// `.dart_tool/package_config.json` (via [Isolate] package resolution layout),
/// not from [Directory.current]. Falls back to the loading isolate's
/// [Platform.script] directory when the package config is unavailable.
///
/// Pass [start] to walk from an explicit directory (fixtures, temp trees).
String findOkaWorkspaceRoot({String? start}) {
  if (start != null) return _walkUpFrom(start);
  final fromPackage = _workspaceRootFromOkaCorePackage();
  if (fromPackage != null) return fromPackage;
  return _walkUpFrom(File.fromUri(Platform.script).absolute.parent.path);
}

String? _workspaceRootFromOkaCorePackage() {
  final coreRoot = _findOkaCorePackageRoot();
  if (coreRoot == null) return null;
  return _walkUpFrom(coreRoot);
}

String? _findOkaCorePackageRoot() {
  final fromIsolateConfig = Platform.packageConfig;
  if (fromIsolateConfig != null) {
    final configFile = fromIsolateConfig.startsWith('file:')
        ? File.fromUri(Uri.parse(fromIsolateConfig))
        : File(fromIsolateConfig);
    if (configFile.existsSync()) {
      final root = _okaCoreRootFromPackageConfig(configFile);
      if (root != null) return root;
    }
  }
  var dir = File.fromUri(Platform.script).absolute.parent;
  while (true) {
    final config = File(p.join(dir.path, '.dart_tool', 'package_config.json'));
    if (config.existsSync()) {
      final root = _okaCoreRootFromPackageConfig(config);
      if (root != null) return root;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

String? _okaCoreRootFromPackageConfig(File config) {
  final doc = jsonDecode(config.readAsStringSync());
  if (doc is! Map) return null;
  final packages = doc['packages'];
  if (packages is! List) return null;
  for (final entry in packages) {
    if (entry is! Map) continue;
    if (entry['name'] != 'oka_core') continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String || rootUri.isEmpty) return null;
    final root = config.parent.uri.resolve(rootUri);
    return File.fromUri(root).absolute.path;
  }
  return null;
}

String _walkUpFrom(String start) {
  var dir = Directory(start).absolute;
  while (true) {
    if (File(p.join(dir.path, okaWorkspaceRootAnchor)).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate oka workspace root (missing $okaWorkspaceRootAnchor) '
        'starting from $start',
      );
    }
    dir = parent;
  }
}
