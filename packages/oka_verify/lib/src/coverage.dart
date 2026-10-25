/// Coverage analysis for the oka verify lane (ADR-0048).
///
/// The import graph answers "which suites does this change reach". It does
/// not answer "could this change reach a suite in a way the graph cannot
/// see". The difference matters: a *known* zero (a source file no suite
/// imports) is information, while an *unknown* (a dependency descriptor, an
/// asset, a file outside every known package) means the affected set may be
/// incomplete — and an incomplete affected set silently skips checks.
///
/// Unknown coverage therefore widens the run instead of narrowing it.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'import_graph.dart';

/// The changed files, split into the ones the graph can reason about and
/// the ones it cannot.
final class CoverageAnalysis {
  const CoverageAnalysis({required this.dartChanges, required this.uncovered});

  /// The changed `.dart` files the graph can attribute to suites.
  final List<String> dartChanges;

  /// The changed files whose effect on the suite set is unknown.
  final List<String> uncovered;

  /// True when at least one change has unknown coverage.
  bool get hasUnknownCoverage => uncovered.isNotEmpty;

  /// The reason a run must widen, or null when the coverage is known.
  String? get broadenReason => uncovered.isEmpty
      ? null
      : 'unknown dependency coverage: ${uncovered.join(', ')}';
}

/// Splits [changedFiles] into graph-attributable changes and changes whose
/// coverage is unknown.
///
/// Unknown coverage comes from three places:
///
/// * a dependency descriptor (`pubspec.yaml`, `pubspec.lock`,
///   `package_config.json`) — the resolution itself changed, so every
///   suite's environment may have changed;
/// * a non-Dart file inside the package under test — assets, fixtures and
///   tooling can be read by a test without appearing in an import;
/// * a `.dart` file outside every known workspace package — the graph has
///   no layout for it, so no edge can be trusted.
CoverageAnalysis analyzeCoverage({
  required List<String> changedFiles,
  required WorkspaceGraph graph,
  required String packageRoot,
}) {
  final dartChanges = <String>[];
  final uncovered = <String>[];
  final packageRoots = graph.packageNames
      .map(graph.packageRoot)
      .whereType<String>()
      .toList();
  for (final file in changedFiles) {
    if (_isDescriptor(file)) {
      uncovered.add(file);
      continue;
    }
    if (!file.endsWith('.dart')) {
      if (_isInside(file, packageRoot)) uncovered.add(file);
      continue;
    }
    if (!packageRoots.any((root) => _isInside(file, root))) {
      uncovered.add(file);
      continue;
    }
    dartChanges.add(file);
  }
  return CoverageAnalysis(dartChanges: dartChanges, uncovered: uncovered);
}

/// True for the files that describe the dependency resolution itself.
bool _isDescriptor(String file) {
  final name = p.basename(file);
  if (name == 'pubspec.yaml' || name == 'pubspec.lock') return true;
  return p.split(file).contains('.dart_tool') && name == 'package_config.json';
}

bool _isInside(String file, String root) {
  final normalizedRoot = p.normalize(root);
  return p.isWithin(normalizedRoot, p.normalize(file)) ||
      p.equals(normalizedRoot, p.normalize(file));
}

/// True when [file] exists (a changed file may have been deleted).
bool fileExists(String path) => File(path).existsSync();
