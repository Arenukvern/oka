import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../release/train_inventory.dart';

/// Content-based duplicate train-inventory detector.
///
/// Flags list, set, or map literals (map **keys** count) outside
/// [canonicalTrainInventoryPath] that embed ≥3 train package name string
/// literals. [SpreadElement] operands that are list/set literals are unwrapped;
/// [IfElement] and [ForElement] bodies are walked recursively (including nested
/// spreads and collection-if).
///
/// **Known limits** (intentionally not flagged):
/// - Lists built from named constants, e.g. `[a, b, c]` when `a`/`b`/`c` are
///   identifiers defined elsewhere.
/// - Dynamic construction such as `'a,b,c'.split(',')`.
///
/// **Per-literal exemption:** place `// train-inventory-scan: allow <reason>`
/// on the line directly above the literal, or on the same line before the
/// opening `[`/`{`. `<reason>` is mandatory and must be non-empty. There is no
/// file-level allowlist.
const canonicalTrainInventoryPath = 'tool/release/train_inventory.dart';

const _minTrainNamesInLiteral = 3;

/// `// train-inventory-scan: allow <non-empty reason>`
final RegExp _allowCommentPattern = RegExp(
  r'//\s*train-inventory-scan:\s*allow\s+(.+)\s*$',
);

final RegExp _allowCommentWithoutReasonPattern = RegExp(
  r'//\s*train-inventory-scan:\s*allow\s*$',
);

final Set<String> _trainPackageNames = packages.toSet();

bool _shouldSkipFile(String rel) {
  if (rel == canonicalTrainInventoryPath) return true;
  if (rel.contains('/.dart_tool/') ||
      rel.startsWith('build/') ||
      rel.contains('/build/')) {
    return true;
  }
  return false;
}

/// Dart files under [root] (excluding [canonicalTrainInventoryPath]) that
/// embed a second train-like list/set/map literal.
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
  if (relPath == canonicalTrainInventoryPath) {
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
    source: source,
    lineInfo: lineInfo,
  );
  parseResult.unit.accept(visitor);
  return visitor.violations;
}

String? _allowReasonOnOrAboveLiteral(
  String source,
  LineInfo lineInfo,
  AstNode node,
) {
  final start = lineInfo.getLocation(node.offset);
  final end = lineInfo.getLocation(node.end);
  final lines = source.split('\n');
  final firstLine0 = start.lineNumber - 1;
  if (firstLine0 < 0 || firstLine0 >= lines.length) return null;

  for (var line0 = firstLine0; line0 >= 0 && line0 >= firstLine0 - 4; line0--) {
    final line = lines[line0];
    if (_allowCommentWithoutReasonPattern.hasMatch(line)) {
      return null;
    }
    final match = _allowCommentPattern.firstMatch(line);
    if (match != null) {
      final reason = match.group(1)!.trim();
      if (reason.isNotEmpty) {
        // Same-line allow must appear before the literal's closing token.
        if (line0 == firstLine0 && line0 == end.lineNumber - 1) {
          final allowIndex = line.indexOf('//');
          final openIndex = line.indexOf(RegExp(r'[\[{]'));
          if (openIndex >= 0 && allowIndex > openIndex) {
            continue;
          }
        }
        return reason;
      }
      return null;
    }
    if (line0 < firstLine0) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('//')) continue;
      break;
    }
  }
  return null;
}

final class _TrainLiteralScanner extends RecursiveAstVisitor<void> {
  _TrainLiteralScanner({
    required this.relPath,
    required this.source,
    required this.lineInfo,
  });

  final String relPath;
  final String source;
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
    _checkLiteral(node, isMap ? 'map' : 'set', node.elements);
    super.visitSetOrMapLiteral(node);
  }

  void _checkLiteral(
    AstNode node,
    String kind,
    NodeList<CollectionElement> elements,
  ) {
    if (_allowReasonOnOrAboveLiteral(source, lineInfo, node) != null) {
      return;
    }
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
    _collectTrainNamesFromCollectionElement(element, found);
  }
  final sorted = found.toList()..sort();
  return sorted;
}

void _collectTrainNamesFromCollectionElement(
  CollectionElement element,
  Set<String> found,
) {
  if (element is MapLiteralEntry) {
    final key = element.key;
    if (key is SimpleStringLiteral &&
        _trainPackageNames.contains(key.value)) {
      found.add(key.value);
    }
    return;
  }
  if (element is IfElement) {
    _collectTrainNamesFromCollectionElement(element.thenElement, found);
    final elseElement = element.elseElement;
    if (elseElement != null) {
      _collectTrainNamesFromCollectionElement(elseElement, found);
    }
    return;
  }
  if (element is ForElement) {
    _collectTrainNamesFromCollectionElement(element.body, found);
    return;
  }
  if (element is SpreadElement) {
    _collectTrainNamesFromExpression(element.expression, found);
    return;
  }
  if (element is Expression) {
    _collectTrainNamesFromExpression(element, found);
  }
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
    _trainNamesInCollection(expression.elements).forEach(found.add);
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

/// Snapshot before IfElement / ForElement collection walks (spreads only).
///
/// For mutation tests only.
List<String> scanDuplicateTrainPackageListsPreIfForUnwrap(
  String relPath,
  String source,
) {
  if (relPath == canonicalTrainInventoryPath) return [];

  final parseResult = parseString(
    content: source,
    featureSet: FeatureSet.latestLanguageVersion(),
    path: relPath,
  );
  if (parseResult.errors.isNotEmpty) return [];
  final visitor = _TrainLiteralScannerPreIfForUnwrap(
    relPath: relPath,
    lineInfo: parseResult.lineInfo,
  );
  parseResult.unit.accept(visitor);
  return visitor.violations..sort();
}

final class _TrainLiteralScannerPreIfForUnwrap extends RecursiveAstVisitor<void> {
  _TrainLiteralScannerPreIfForUnwrap({
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
    _checkLiteral(node, isMap ? 'map' : 'set', node.elements);
    super.visitSetOrMapLiteral(node);
  }

  void _checkLiteral(
    AstNode node,
    String kind,
    NodeList<CollectionElement> elements,
  ) {
    final names = _trainNamesInCollectionPreIfForUnwrap(elements);
    if (names.length >= _minTrainNamesInLiteral) {
      final location = lineInfo.getLocation(node.offset);
      violations.add(
        '$relPath:${location.lineNumber}:${location.columnNumber}: '
        '$kind literal contains ${names.length} train package names',
      );
    }
  }
}

List<String> _trainNamesInCollectionPreIfForUnwrap(
  NodeList<CollectionElement> elements,
) {
  final found = <String>{};
  for (final element in elements) {
    if (element is MapLiteralEntry) {
      final key = element.key;
      if (key is SimpleStringLiteral &&
          _trainPackageNames.contains(key.value)) {
        found.add(key.value);
      }
      continue;
    }
    if (element is SpreadElement) {
      _collectTrainNamesFromExpressionPreIfForUnwrap(element.expression, found);
      continue;
    }
    if (element is Expression) {
      _collectTrainNamesFromExpressionPreIfForUnwrap(element, found);
    }
  }
  final sorted = found.toList()..sort();
  return sorted;
}

void _collectTrainNamesFromExpressionPreIfForUnwrap(
  Expression expression,
  Set<String> found,
) {
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
    _collectTrainNamesFromExpressionPreIfForUnwrap(expression.expression, found);
    return;
  }
  if (expression is ListLiteral) {
    _trainNamesInCollectionPreIfForUnwrap(expression.elements).forEach(found.add);
  }
  if (expression is SetOrMapLiteral) {
    _trainNamesInCollectionPreIfForUnwrap(expression.elements).forEach(found.add);
  }
}

/// Snapshot of the 0d819ce1 scanner (file allowlist, maps skipped, no spreads).
///
/// For mutation tests only.
List<String> scanDuplicateTrainPackageListsAt0d819ce1(
  String relPath,
  String source,
) {
  if (relPath == canonicalTrainInventoryPath) return [];
  if (relPath == 'tool/contracts/check_architecture.dart') return [];

  final parseResult = parseString(
    content: source,
    featureSet: FeatureSet.latestLanguageVersion(),
    path: relPath,
  );
  if (parseResult.errors.isNotEmpty) return [];
  final visitor = _TrainLiteralScanner0d819ce1(
    relPath: relPath,
    lineInfo: parseResult.lineInfo,
  );
  parseResult.unit.accept(visitor);
  return visitor.violations..sort();
}

final class _TrainLiteralScanner0d819ce1 extends RecursiveAstVisitor<void> {
  _TrainLiteralScanner0d819ce1({
    required this.relPath,
    required this.lineInfo,
  });

  final String relPath;
  final LineInfo lineInfo;
  final List<String> violations = [];

  @override
  void visitListLiteral(ListLiteral node) {
    _check(node, 'list', node.elements);
    super.visitListLiteral(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    final isMap = node.elements.any((e) => e is MapLiteralEntry);
    if (!isMap) {
      _check(node, 'set', node.elements);
    }
    super.visitSetOrMapLiteral(node);
  }

  void _check(AstNode node, String kind, NodeList<CollectionElement> elements) {
    final found = <String>{};
    for (final element in elements) {
      if (element is Expression) {
        _expr(element, found);
      }
    }
    final names = found.toList()..sort();
    if (names.length >= _minTrainNamesInLiteral) {
      final location = lineInfo.getLocation(node.offset);
      violations.add(
        '$relPath:${location.lineNumber}:${location.columnNumber}: '
        '$kind literal contains ${names.length} train package names',
      );
    }
  }

  void _expr(Expression expression, Set<String> found) {
    if (expression is SimpleStringLiteral &&
        _trainPackageNames.contains(expression.value)) {
      found.add(expression.value);
    } else if (expression is ListLiteral) {
      for (final element in expression.elements) {
        if (element is Expression) _expr(element, found);
      }
    } else if (expression is SetOrMapLiteral) {
      final isMap = expression.elements.any((e) => e is MapLiteralEntry);
      if (!isMap) {
        for (final element in expression.elements) {
          if (element is Expression) _expr(element, found);
        }
      }
    }
  }
}
