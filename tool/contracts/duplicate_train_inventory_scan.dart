import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../release/train_inventory.dart';

/// Canonical inventory — the only file that may embed a full train package list.
const canonicalTrainInventoryPath = 'tool/release/train_inventory.dart';

/// Paths exempt from duplicate-inventory detection (relative to repo root).
///
/// Add entries only when a test must spell package order explicitly; keep empty
/// unless genuinely needed.
const duplicateTrainInventoryAllowlist = <({String path, String reason})>[
  (
    path: 'tool/contracts/check_architecture.dart',
    reason:
        'Per-package forbidden import sets (architecture gates), not train inventory',
  ),
];

const _minTrainNamesInLiteral = 3;

final Set<String> _trainPackageNames = packages.toSet();

bool _isAllowlisted(String relPath) {
  for (final entry in duplicateTrainInventoryAllowlist) {
    if (entry.path == relPath) return true;
  }
  return false;
}

bool _shouldSkipFile(String rel) {
  if (rel == canonicalTrainInventoryPath) return true;
  if (_isAllowlisted(rel)) return true;
  if (rel.contains('/.dart_tool/') ||
      rel.startsWith('build/') ||
      rel.contains('/build/')) {
    return true;
  }
  return false;
}

/// Dart files under [root] (excluding [canonicalTrainInventoryPath] and
/// [duplicateTrainInventoryAllowlist]) that embed a second train-like list/set.
List<String> findDuplicateTrainPackageLists(Directory root) {
  final offenders = <String>[];
  final trainRoot = p.normalize(root.path);
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final rel = p
        .relative(entity.path, from: trainRoot)
        .replaceAll(r'\', '/');
    if (_shouldSkipFile(rel)) continue;
    final source = entity.readAsStringSync();
    offenders.addAll(_scanFileSource(rel, source));
  }
  offenders.sort();
  return offenders;
}

/// Scans one file's [source] (for tests). [relPath] is shown in violation text.
List<String> scanDuplicateTrainPackageListsInSource(
  String relPath,
  String source,
) {
  if (relPath == canonicalTrainInventoryPath ||
      _isAllowlisted(relPath)) {
    return [];
  }
  return _scanFileSource(relPath, source)..sort();
}

List<String> _scanFileSource(String relPath, String source) {
  final parseResult = parseString(
    content: source,
    featureSet: FeatureSet.latestLanguageVersion(),
    path: relPath,
  );
  if (parseResult.errors.isNotEmpty) {
    final detail = parseResult.errors.map((e) => e.message).join('; ');
    return ['$relPath:1: parse errors: $detail'];
  }
  final lineInfo = parseResult.lineInfo;
  final visitor = _TrainLiteralScanner(
    relPath: relPath,
    lineInfo: lineInfo,
  );
  parseResult.unit.accept(visitor);
  return visitor.violations;
}

final class _TrainLiteralScanner extends RecursiveAstVisitor<void> {
  _TrainLiteralScanner({
    required this.relPath,
    required this.lineInfo,
  });

  final String relPath;
  final LineInfo lineInfo;
  final List<String> violations = [];

  @override
  void visitListLiteral(ListLiteral node) {
    _checkLiteral(node, 'list', node.elements);
    super.visitListLiteral(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    final isMap = node.elements.any((e) => e is MapLiteralEntry);
    if (!isMap) {
      _checkLiteral(node, 'set', node.elements);
    }
    super.visitSetOrMapLiteral(node);
  }

  void _checkLiteral(AstNode node, String kind, NodeList<CollectionElement> elements) {
    final names = _trainNamesInCollection(elements);
    if (names.length >= _minTrainNamesInLiteral) {
      final location = lineInfo.getLocation(node.offset);
      violations.add(
        '$relPath:${location.lineNumber}:${location.columnNumber}: '
        '$kind literal contains ${names.length} train package names '
        '(${names.take(5).join(', ')}${names.length > 5 ? ', …' : ''})',
      );
    }
  }
}

List<String> _trainNamesInCollection(NodeList<CollectionElement> elements) {
  final found = <String>{};
  for (final element in elements) {
    if (element is Expression) {
      _collectTrainNamesFromExpression(element, found);
    }
  }
  final sorted = found.toList()..sort();
  return sorted;
}

void _collectTrainNamesFromExpression(Expression expression, Set<String> found) {
  if (expression is SimpleStringLiteral) {
    final value = expression.value;
    if (_trainPackageNames.contains(value)) {
      found.add(value);
    }
    return;
  }
  if (expression is StringInterpolation) {
    return;
  }
  if (expression is ParenthesizedExpression) {
    _collectTrainNamesFromExpression(expression.expression, found);
    return;
  }
  if (expression is ListLiteral) {
    _trainNamesInCollection(expression.elements).forEach(found.add);
  }
  if (expression is SetOrMapLiteral) {
    final isMap = expression.elements.any((e) => e is MapLiteralEntry);
    if (!isMap) {
      _trainNamesInCollection(expression.elements).forEach(found.add);
    }
  }
}

/// Previous line-regex scanner (mutation baseline — misses renamed / multiline lists).
List<String> findDuplicateTrainPackageListsLineBased(Directory root) {
  // Exact PR #34 pre-content patterns (FMT mutation baseline).
  final patterns = <RegExp>[
    RegExp(r'const\s+packages\s*=\s*<String>\s*\['),
    RegExp(r'const\s+trainPackages\s*=\s*\['),
    RegExp(r'trainPackagesForWorkspaceLeakScan\s*=\s*<String>\s*\['),
  ];
  final offenders = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final rel = p
        .relative(entity.path, from: root.path)
        .replaceAll(r'\', '/');
    if (rel == canonicalTrainInventoryPath) continue;
    if (_shouldSkipFile(rel)) continue;
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      for (final pattern in patterns) {
        if (pattern.hasMatch(line)) {
          offenders.add('$rel:${i + 1}: ${line.trim()}');
          break;
        }
      }
    }
  }
  offenders.sort();
  return offenders;
}
