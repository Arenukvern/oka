/// Workspace import graph for the oka verify lane (ADR-0048).
///
/// Dependency-free on purpose: a directive scan (import/export/part) is
/// enough to answer "which test suites transitively reach this file", and
/// staying off `package:analyzer` keeps the lane bootable by the same
/// plain `dart run` that drives it.
///
/// The scan follows **every** directive URI, including all branches of a
/// conditional import. A branch that is not taken on this platform is still
/// an edge the cache cannot prove irrelevant, so it is kept: a redundant
/// rebuild costs seconds, a missed invalidation costs a false green.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The workspace import graph: which file reaches which, and therefore
/// which test suites a changed file can affect.
final class WorkspaceGraph {
  WorkspaceGraph({
    required this.repoRoot,
    required Map<String, String> packages,
  }) : _packages = Map.of(packages);

  /// Repository root (the workspace root owning `package_config.json`).
  final String repoRoot;

  /// Workspace package name -> absolute root dir.
  final Map<String, String> _packages;

  final Map<String, List<String>> _importsByFile = {};
  final Map<String, List<String>> _directivesByFile = {};

  /// Discard navigation hints before checking a new source revision.
  void refresh() {
    _importsByFile.clear();
    _directivesByFile.clear();
  }

  /// Loads the workspace layout from `<root>/.dart_tool/package_config.json`.
  static Future<WorkspaceGraph> load(String repoRoot) async {
    final config = File('$repoRoot/.dart_tool/package_config.json');
    if (!config.existsSync()) {
      throw StateError('missing ${config.path} — run `dart pub get` first');
    }
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw StateError('malformed ${config.path}');
    }
    final configDir = config.parent.path;
    final packages = <String, String>{};
    for (final entry in decoded['packages']! as List<Object?>) {
      final pkg = entry! as Map<String, Object?>;
      final name = pkg['name'];
      final rootUriValue = pkg['rootUri'];
      if (name is! String || rootUriValue is! String) continue;
      final rootUri = Uri.parse(rootUriValue);
      final root = rootUri.scheme == 'file'
          ? rootUri.toFilePath()
          : Uri.directory('$configDir/').resolveUri(rootUri).toFilePath();
      packages[name] = _noTrailingSlash(Directory(root).absolute.path);
    }
    return WorkspaceGraph(
      repoRoot: _noTrailingSlash(Directory(repoRoot).absolute.path),
      packages: packages,
    );
  }

  static String _noTrailingSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// The root directory of a workspace package, or null when the package is
  /// not part of this workspace.
  String? packageRoot(String packageName) => _packages[packageName];

  /// Every workspace package name known to the graph.
  List<String> get packageNames => _packages.keys.toList()..sort();

  /// Test suites (`test/**/*_test.dart`) of one workspace package.
  List<String> testSuites(String packageRoot) {
    final suites = <String>[];
    final testDir = Directory('$packageRoot/test');
    if (!testDir.existsSync()) return suites;
    for (final entry in testDir.listSync(recursive: true)) {
      if (entry is! File) continue;
      if (entry.path.endsWith('_test.dart')) suites.add(entry.path);
    }
    return suites..sort();
  }

  /// Transitive workspace closure of one file (the file itself included),
  /// following import/export/part edges, including neighboring path packages.
  List<String> closureOf(String file) {
    final seen = <String>{};
    final queue = Queue<String>()..add(file);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (!seen.add(current)) continue;
      for (final next in _importsOf(current)) {
        if (!seen.contains(next)) queue.add(next);
      }
    }
    return seen.toList()..sort();
  }

  /// Suites among [suites] whose closure reaches any of [changed].
  Set<String> affectedSuites(Iterable<String> changed, List<String> suites) {
    final changedSet = changed.toSet();
    return {
      for (final suite in suites)
        if (closureOf(suite).any(changedSet.contains)) suite,
    };
  }

  /// The raw directive URIs of one file, in source order. Every branch of a
  /// conditional import is included; `package:` and relative URIs are not
  /// distinguished here.
  List<String> directiveUris(String file) =>
      _directivesByFile.putIfAbsent(file, () => _scanDirectives(file));

  /// True when [file] (or anything in its closure) reaches Flutter. Flutter
  /// suites need the `flutter_tester` shell, so the lane refuses them
  /// instead of running them.
  bool reachesFlutter(String file) {
    for (final member in closureOf(file)) {
      if (directiveUris(member).any(_isFlutterUri)) return true;
    }
    return false;
  }

  /// Imported native-asset packages must use normal SDK hook handling.
  /// Unrelated packages in package_config are not dependencies of a suite.
  bool reachesNativeAssets(String file) {
    final hookedRoots = [
      for (final root in _packages.values)
        if (File(p.join(root, 'hook', 'build.dart')).existsSync() ||
            File(p.join(root, 'hook', 'link.dart')).existsSync())
          root,
    ];
    for (final member in closureOf(file)) {
      if (directiveUris(member).contains('dart:ffi')) return true;
      if (hookedRoots.any((root) => p.isWithin(root, member))) return true;
    }
    return false;
  }

  static bool _isFlutterUri(String uri) =>
      uri.startsWith('package:flutter/') ||
      uri.startsWith('package:flutter_test/');

  List<String> _importsOf(String file) => _importsByFile.putIfAbsent(
    file,
    () =>
        directiveUris(file).map((uri) => _resolve(uri, file)).nonNulls.toList(),
  );

  /// Scans one file for import/export/part directives and returns every URI
  /// they mention. Comments are skipped; a directive ends at its `;`.
  List<String> _scanDirectives(String file) {
    final source = File(file);
    if (!source.existsSync()) return const [];
    final text = source.readAsStringSync();
    final uris = <String>[];
    for (final start in _directiveStarts(text)) {
      uris.addAll(_urisInDirective(text, start));
    }
    return uris;
  }

  // Scan lexical boundaries rather than lines: Dart permits multiple
  // directives on one line and comments between a semicolon and import.
  static Iterable<int> _directiveStarts(String text) sync* {
    var index = 0;
    while (index < text.length) {
      if (text.startsWith('//', index)) {
        final end = text.indexOf('\n', index + 2);
        index = end < 0 ? text.length : end + 1;
      } else if (text.startsWith('/*', index)) {
        var depth = 1;
        index += 2;
        while (index < text.length && depth > 0) {
          if (text.startsWith('/*', index)) {
            depth++;
            index += 2;
          } else if (text.startsWith('*/', index)) {
            depth--;
            index += 2;
          } else {
            index++;
          }
        }
      } else if (text[index] == "'" || text[index] == '"') {
        final quote = text[index];
        final triple = text.startsWith(quote * 3, index);
        final delimiter = triple ? quote * 3 : quote;
        index += delimiter.length;
        while (index < text.length) {
          if (text[index] == r'\') {
            index += 2;
          } else if (text.startsWith(delimiter, index)) {
            index += delimiter.length;
            break;
          } else {
            index++;
          }
        }
      } else if (_identifier.hasMatch(text[index])) {
        final start = index++;
        while (index < text.length && _identifier.hasMatch(text[index])) {
          index++;
        }
        final token = text.substring(start, index);
        if (token == 'import' || token == 'export' || token == 'part') {
          yield index;
        }
      } else {
        index++;
      }
    }
  }

  static final _identifier = RegExp(r'[a-zA-Z0-9_$]');

  /// Collects the quoted URIs of the directive that starts at [start],
  /// stopping at the terminating `;`. Line and block comments are skipped so
  /// a quoted word inside a comment never becomes an edge.
  static List<String> _urisInDirective(String text, int start) {
    final uris = <String>[];
    var index = start;
    final length = text.length;
    var inLineComment = false;
    var inBlockComment = false;
    while (index < length) {
      final char = text[index];
      if (inLineComment) {
        if (char == '\n') inLineComment = false;
        index++;
        continue;
      }
      if (inBlockComment) {
        if (char == '*' && index + 1 < length && text[index + 1] == '/') {
          inBlockComment = false;
          index += 2;
          continue;
        }
        index++;
        continue;
      }
      if (char == '/' && index + 1 < length && text[index + 1] == '/') {
        inLineComment = true;
        index += 2;
        continue;
      }
      if (char == '/' && index + 1 < length && text[index + 1] == '*') {
        inBlockComment = true;
        index += 2;
        continue;
      }
      if (char == ';') break;
      if (char == "'" || char == '"') {
        final quote = char;
        final end = text.indexOf(quote, index + 1);
        if (end < 0) break;
        final uri = text.substring(index + 1, end);
        if (_looksLikeUri(uri)) uris.add(uri);
        index = end + 1;
        continue;
      }
      index++;
    }
    return uris;
  }

  /// A directive URI is a path or a `package:` URI — not a library name.
  static bool _looksLikeUri(String uri) =>
      uri.startsWith('dart:') || uri.contains('/') || uri.endsWith('.dart');

  /// Resolves one directive uri to a workspace file, or null when the
  /// target is SDK or an unresolved package. Missing paths stay in the key.
  String? _resolve(String uri, String fromFile) {
    if (uri.startsWith('dart:')) return null;
    String target;
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash <= 0) return null;
      final root = _packages[rest.substring(0, slash)];
      if (root == null) return null;
      target = p.normalize('$root/lib/${rest.substring(slash + 1)}');
    } else {
      target = p.normalize(p.join(p.dirname(fromFile), uri));
    }
    // Missing paths remain edges: creating a conditional-import target
    // must invalidate a previously compiled kernel too.
    // Path dependencies can be edited without changing package_config.
    // Hash their actual source too; a repository boundary is not a cache
    // invalidation boundary. SDK URIs were excluded above.
    return target;
  }
}
