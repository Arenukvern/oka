// Monorepo-only — not published. Hosted `oka_core` consumers must not depend on
// this helper (there is no `tool/release/train.dart` in the pub cache).
//
// Root tests: `import 'support/repo_root.dart';`
// Package tests: `import '../../../test/support/repo_root.dart';`
// Tool scripts: `import '../../test/support/repo_root.dart';`

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Anchor file checked in at the oka monorepo root.
const okaWorkspaceRootAnchor = 'tool/release/train.dart';

/// Resolves the oka monorepo root by walking parents from the workspace
/// `oka_core` package root (via [Platform.packageConfig]), not
/// [Directory.current].
///
/// Pass [start] to walk from an explicit directory (temp fixtures).
///
/// Throws when this isolate has no package config or `oka_core` is not in the
/// graph (e.g. a hosted-only pub cache checkout).
String findOkaWorkspaceRoot({String? start}) {
  if (start != null) return _walkUpFrom(start);
  final fromEnv = Platform.environment['OKA_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return _walkUpFrom(fromEnv);
  }
  final coreRoot = _findOkaCorePackageRoot();
  if (coreRoot == null) {
    throw StateError(
      'findOkaWorkspaceRoot is monorepo-only: no package config with '
      'oka_core (run from the workspace after `dart pub get`).',
    );
  }
  return _walkUpFrom(coreRoot);
}

String? _findOkaCorePackageRoot() {
  final fromIsolateConfig = Platform.packageConfig;
  if (fromIsolateConfig == null) return null;
  final configFile = fromIsolateConfig.startsWith('file:')
      ? File.fromUri(Uri.parse(fromIsolateConfig))
      : File(fromIsolateConfig);
  if (!configFile.existsSync()) return null;
  return _okaCoreRootFromPackageConfig(configFile);
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
