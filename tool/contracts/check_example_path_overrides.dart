import 'dart:io';

import 'package:yaml/yaml.dart';

Never _fail(String message) {
  stderr.writeln('check_example_path_overrides: $message');
  exit(1);
}

String _packagesDir(Directory root) =>
    '${root.path}${Platform.pathSeparator}packages';

/// Workspace package names under [root]/packages (from each pubspec `name:`).
Set<String> workspacePackageNames(Directory root) {
  final packagesDir = Directory(_packagesDir(root));
  if (!packagesDir.existsSync()) return {};
  final names = <String>{};
  for (final entity in packagesDir.listSync()) {
    if (entity is! Directory) continue;
    final manifest = File('${entity.path}/pubspec.yaml');
    if (!manifest.existsSync()) continue;
    final doc = loadYaml(manifest.readAsStringSync());
    if (doc is! YamlMap) continue;
    final name = doc['name'];
    if (name is String && name.isNotEmpty) names.add(name);
  }
  return names;
}

bool _isPathRef(Object? node) {
  if (node is! YamlMap) return false;
  final path = node['path'];
  return path is String && path.isNotEmpty;
}

/// Package names resolved via `path:` under [section] in [examplePubspec].
Set<String> pathResolvedInSection(YamlMap examplePubspec, String section) {
  final block = examplePubspec[section];
  if (block is! YamlMap) return {};
  final names = <String>{};
  for (final entry in block.entries) {
    final key = entry.key;
    if (key is! String) continue;
    if (_isPathRef(entry.value)) names.add(key);
  }
  return names;
}

Set<String> examplePathSeeds(YamlMap examplePubspec) => {
      ...pathResolvedInSection(examplePubspec, 'dependencies'),
      ...pathResolvedInSection(examplePubspec, 'dependency_overrides'),
    };

Set<String> examplePathOverrides(YamlMap examplePubspec) =>
    pathResolvedInSection(examplePubspec, 'dependency_overrides');

/// Reads regular [dependencies] (not dev_dependencies) workspace refs from a
/// package manifest.
Set<String> workspaceDependencies(
  Directory root,
  String packageName,
  Set<String> workspaceNames,
) {
  final manifest = File(
    '${_packagesDir(root)}${Platform.pathSeparator}$packageName/pubspec.yaml',
  );
  if (!manifest.existsSync()) return {};
  final doc = loadYaml(manifest.readAsStringSync());
  if (doc is! YamlMap) return {};
  final deps = doc['dependencies'];
  if (deps is! YamlMap) return {};
  final found = <String>{};
  for (final entry in deps.entries) {
    final key = entry.key;
    if (key is String && workspaceNames.contains(key)) found.add(key);
  }
  return found;
}

/// Transitive closure of workspace packages reachable via `dependencies` from
/// [example] path seeds (path deps / overrides).
Set<String> reachableWorkspacePackages(Directory root, YamlMap examplePubspec) {
  final workspaceNames = workspacePackageNames(root);
  final seeds = examplePathSeeds(examplePubspec);
  final closure = <String>{...seeds.intersection(workspaceNames)};
  final queue = List<String>.from(closure);
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final dep in workspaceDependencies(root, current, workspaceNames)) {
      if (closure.add(dep)) queue.add(dep);
    }
  }
  return closure;
}

/// Packages in the closure that lack a `dependency_overrides` path entry.
///
/// Direct `dependencies` path entries (e.g. `oka_update`) satisfy resolution
/// without an override — they are excluded from this set.
List<String> missingExamplePathOverrides(Directory root) {
  final exampleFile = File('${root.path}/example/pubspec.yaml');
  if (!exampleFile.existsSync()) {
    _fail('example/pubspec.yaml not found (${exampleFile.path})');
  }
  final examplePubspec = loadYaml(exampleFile.readAsStringSync());
  if (examplePubspec is! YamlMap) {
    _fail('example/pubspec.yaml: expected a YAML mapping');
  }

  final closure = reachableWorkspacePackages(root, examplePubspec);
  final overrides = examplePathOverrides(examplePubspec);
  final directPathDeps = pathResolvedInSection(examplePubspec, 'dependencies');

  final missing = <String>[];
  for (final name in closure) {
    if (overrides.contains(name)) continue;
    if (directPathDeps.contains(name)) continue;
    missing.add(name);
  }
  missing.sort();
  return missing;
}

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  final missing = missingExamplePathOverrides(root);
  if (missing.isNotEmpty) {
    _fail(
      'example/pubspec.yaml must path-override every workspace package '
      'reachable from its path deps; missing dependency_overrides for: '
      '[${missing.map((n) => "'$n'").join(', ')}]. '
      'Add `path: ../packages/<name>` entries under dependency_overrides.',
    );
  }
  stdout.writeln(
    'check_example_path_overrides: example path-override closure ok',
  );
}
