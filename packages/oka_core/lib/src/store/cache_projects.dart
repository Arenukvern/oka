import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Results from a bounded scan of explicitly selected project roots.
final class ProjectDiscovery {
  ProjectDiscovery({
    required List<String> projects,
    required List<String> warnings,
  }) : projects = List.unmodifiable(projects),
       warnings = List.unmodifiable(warnings);

  final List<String> projects;
  final List<String> warnings;
  bool get complete => warnings.isEmpty;

  Map<String, Object> toJson() => {
    'projects': projects,
    'warnings': warnings,
    'complete': complete,
  };
}

/// Remembers project locations without placing user metadata in a prunable store.
///
/// Writes are atomic and serialized across processes using an adjacent lock file.
/// Stale entries remain recorded but [projects] returns only existing caches.
final class CacheProjectRegistry {
  CacheProjectRegistry({String? path, Map<String, String>? environment})
    : path = path ?? _defaultPath(environment ?? Platform.environment);

  final String path;

  static final Map<String, Future<void>> _pendingWrites = {};

  static String _defaultPath(Map<String, String> environment) {
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'Cannot locate home directory for the cache project registry.',
      );
    }
    return p.join(home, '.oka', 'cache-projects.json');
  }

  Future<Set<String>> _read() async {
    final file = File(path);
    if (!await file.exists()) return {};
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value['schema_version'] != 1 ||
        value['projects'] is! List) {
      throw FormatException('Invalid cache project registry: $path');
    }
    final result = <String>{};
    for (final entry in value['projects'] as List) {
      if (entry is! String ||
          !p.isAbsolute(entry) ||
          p.dirname(p.normalize(entry)) == p.normalize(entry)) {
        throw FormatException(
          'Invalid project path in cache project registry: $path',
        );
      }
      result.add(p.normalize(entry));
    }
    return result;
  }

  /// Reads registry metadata without filtering missing caches or writing.
  /// Invalid sibling entries are preserved as issues so callers can report a
  /// partial snapshot while mutation APIs continue to fail closed.
  Future<CacheProjectRegistrySnapshot> inspect() async {
    final file = File(path);
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return const CacheProjectRegistrySnapshot(schemaStatus: 'missing');
      }
      if (type != FileSystemEntityType.file ||
          await FileSystemEntity.type(p.dirname(path), followLinks: false) ==
              FileSystemEntityType.link) {
        return CacheProjectRegistrySnapshot(
          schemaStatus: 'invalid',
          issues: [
            CacheProjectRegistryIssue(
              path: path,
              code: 'excluded_path',
              message:
                  'Registry is not a regular file or its directory is a symbolic link.',
            ),
          ],
        );
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) {
        return CacheProjectRegistrySnapshot(
          schemaStatus: 'invalid',
          issues: [
            CacheProjectRegistryIssue(
              path: path,
              code: 'invalid_schema',
              message: 'Registry root must be an object.',
            ),
          ],
        );
      }
      final issues = <CacheProjectRegistryIssue>[];
      final schema = value['schema_version'];
      final status = schema == 1 ? 'valid' : 'invalid';
      if (schema != 1) {
        issues.add(
          CacheProjectRegistryIssue(
            path: path,
            code: 'invalid_schema',
            message: 'Expected schema_version 1.',
          ),
        );
      }
      final raw = value['projects'];
      final projects = <String>[];
      if (raw is! List) {
        issues.add(
          CacheProjectRegistryIssue(
            path: path,
            code: 'invalid_projects',
            message: 'projects must be a list.',
          ),
        );
      } else {
        for (var index = 0; index < raw.length; index++) {
          final entry = raw[index];
          if (entry is! String ||
              !p.isAbsolute(entry) ||
              p.dirname(p.normalize(entry)) == p.normalize(entry)) {
            issues.add(
              CacheProjectRegistryIssue(
                path: path,
                code: 'invalid_project',
                message: 'Invalid project entry at index $index.',
              ),
            );
          } else {
            if (!projects.contains(p.normalize(entry))) {
              projects.add(p.normalize(entry));
            }
          }
        }
      }
      projects.sort();
      issues.sort((a, b) => a.message.compareTo(b.message));
      return CacheProjectRegistrySnapshot(
        schemaStatus: status,
        projects: projects,
        issues: issues,
      );
    } on Object catch (error) {
      return CacheProjectRegistrySnapshot(
        schemaStatus: 'invalid',
        issues: [
          CacheProjectRegistryIssue(
            path: path,
            code: 'unreadable',
            message: error.toString(),
          ),
        ],
      );
    }
  }

  Future<List<String>> projects() async {
    final result = <String>[];
    for (final project in await _read()) {
      if (await _isProject(project)) result.add(project);
    }
    return result..sort();
  }

  Future<void> register(String projectPath) async {
    final canonical = await Directory(projectPath).resolveSymbolicLinks();
    if (p.dirname(canonical) == canonical) {
      throw ArgumentError.value(
        projectPath,
        'projectPath',
        'Filesystem root is not a project',
      );
    }
    await _merge({canonical});
  }

  Future<void> _merge(Set<String> additions) async {
    final key = p.normalize(p.absolute(path));
    final previous = _pendingWrites[key];
    final operation = () async {
      if (previous != null) {
        // One failed write must not prevent subsequent valid registrations.
        try {
          await previous;
        } on Object {
          // The original caller receives the failure.
        }
      }
      await _mergeLocked(additions);
    }();
    _pendingWrites[key] = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingWrites[key], operation)) {
        unawaited(_pendingWrites.remove(key));
      }
    }
  }

  Future<void> _mergeLocked(Set<String> additions) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final lock = await File('$path.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final entries = await _read();
      if (entries.containsAll(additions)) return;
      entries.addAll(additions);
      final sorted = entries.toList()..sort();
      final temporary = await file.parent.createTemp('.cache-projects-');
      try {
        final staged = File(p.join(temporary.path, 'registry.json'));
        await staged.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'projects': sorted})}\n',
          flush: true,
        );
        await staged.rename(path);
      } finally {
        await temporary.delete(recursive: true);
      }
    } finally {
      await lock.close();
    }
  }

  static Future<bool> _isProject(String directory) async =>
      await FileSystemEntity.type(directory, followLinks: false) ==
          FileSystemEntityType.directory &&
      await FileSystemEntity.type(
            p.join(directory, '.oka_cache'),
            followLinks: false,
          ) ==
          FileSystemEntityType.directory &&
      await Directory(directory).resolveSymbolicLinks() ==
          p.normalize(directory);

  /// Discovers cache-bearing projects without following links or implicit roots.
  ///
  /// Explicit roots are canonicalized (allowing OS aliases such as `/var`).
  /// Links encountered below these roots are never traversed. All discovered
  /// paths are registered, even when a bound makes the scan incomplete.
  Future<ProjectDiscovery> discover(
    List<String> roots, {
    int maxDepth = 12,
    int maxDirectories = 50000,
  }) async {
    if (maxDepth < 0 || maxDirectories < 1) {
      throw ArgumentError(
        'Discovery bounds must be nonnegative depth and positive directory count.',
      );
    }
    // Validate existing metadata before performing any work or writes.
    await _read();
    final found = <String>{};
    final warnings = <String>[];
    final visited = <String>{};
    var exhausted = false;
    Future<void> visit(String directory, int depth) async {
      if (visited.contains(directory) || exhausted) return;
      if (visited.length >= maxDirectories) {
        warnings.add(
          'Directory limit ($maxDirectories) reached; discovery is incomplete.',
        );
        exhausted = true;
        return;
      }
      visited.add(directory);
      try {
        if (await _isProject(directory)) found.add(directory);
        await for (final child in Directory(
          directory,
        ).list(followLinks: false)) {
          if (child is! Directory) continue;
          final name = p.basename(child.path);
          if (name.startsWith('.') ||
              const {
                'node_modules',
                'build',
                'Pods',
                'vendor',
              }.contains(name)) {
            continue;
          }
          if (depth >= maxDepth) {
            warnings.add('Depth limit ($maxDepth) reached at ${child.path}.');
            continue;
          }
          await visit(child.path, depth + 1);
          if (exhausted) break;
        }
      } on FileSystemException catch (error) {
        warnings.add('Cannot scan $directory: ${error.message}');
      }
    }

    for (final root in roots) {
      try {
        final canonical = await Directory(root).resolveSymbolicLinks();
        if (p.dirname(canonical) == canonical) {
          throw ArgumentError.value(
            root,
            'roots',
            'Scanning the filesystem root is not supported',
          );
        }
        await visit(canonical, 0);
      } on FileSystemException catch (error) {
        warnings.add('Cannot scan $root: ${error.message}');
      }
    }
    if (found.isNotEmpty) await _merge(found);
    return ProjectDiscovery(
      projects: found.toList()..sort(),
      warnings: warnings,
    );
  }
}

final class CacheProjectRegistryIssue {
  const CacheProjectRegistryIssue({
    required this.path,
    required this.code,
    required this.message,
  });
  final String path;
  final String code;
  final String message;
}

final class CacheProjectRegistrySnapshot {
  const CacheProjectRegistrySnapshot({
    required this.schemaStatus,
    this.projects = const [],
    this.issues = const [],
  });
  final String schemaStatus;

  /// All syntactically valid recorded paths, including missing caches.
  final List<String> projects;
  final List<CacheProjectRegistryIssue> issues;
  bool get complete => issues.isEmpty && schemaStatus == 'valid';
}
