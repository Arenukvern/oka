import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;

import '../cache/session_state_paths.dart';

typedef SessionStateSnapshotReader =
    Future<SessionStateRegistrySnapshot> Function();

/// Clean command to clear build caches
class CleanCommand {
  CleanCommand({
    SessionStateSnapshotReader? inspectSessionStates,
    String? currentDirectory,
    Map<String, String>? environment,
    void Function(String)? output,
  }) : _inspectSessionStates =
           inspectSessionStates ??
           (() => SessionStateRegistry.forCurrentUser(
             homeDirectory:
                 (environment ?? Platform.environment)['HOME'] ??
                 (environment ?? Platform.environment)['USERPROFILE'] ??
                 (environment ?? Platform.environment)['APPDATA'],
           ).inspect()),
       _currentDirectory = currentDirectory ?? Directory.current.path,
       _environment = environment ?? Platform.environment,
       _output = output ?? print;

  final SessionStateSnapshotReader _inspectSessionStates;
  final String _currentDirectory;
  final Map<String, String> _environment;
  final void Function(String) _output;

  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('full', negatable: false, help: 'Clear dependency cache too')
      ..addFlag('ai-cache', negatable: false, help: 'Clear AI conversion cache')
      ..addFlag(
        'android-sdk',
        negatable: false,
        help: 'Remove oka-managed Android SDK (~/.oka/android-sdk)',
      );

    final results = parser.parse(args);

    if (results['android-sdk'] as bool) {
      print('🧹 Cleaning oka-managed Android SDK...');
      final installer = AndroidSdkInstaller();
      final result = await installer.cleanup();
      if (result.success) {
        print('  ✅ ${result.message}');
      } else {
        print('  ❌ ${result.message}');
        exit(1);
      }
      print('\n✅ Clean complete!');
      return;
    }

    _output('🧹 Cleaning build cache...');
    final protection = await _sessionStateCleanupProtection();
    if (protection.paths.isNotEmpty) {
      _output(
        '  ℹ️  Session-state deletion is protected against known paths, but '
        'not against same-user filesystem races.',
      );
    }
    if (protection.blockers.isNotEmpty) {
      _output('  ❌ Refusing to clean caches:');
      for (final blocker in protection.blockers) {
        _output('     $blocker');
      }
      _output('  Remedies:');
      _output(
        '    Run `oka session-state list --json` and inspect each reported '
        'registry record path.',
      );
      _output(
        '    Back up and repair or restore the affected registry record, '
        'then retry `oka clean`.',
      );
      _output(
        '    Do not delete session-state resource data or the registry '
        'directory to bypass this safety check.',
      );
      exitCode = 1;
      return;
    }

    // Clean local build cache
    final buildCache = Directory(p.join(_currentDirectory, '.oka_cache'));
    if (await buildCache.exists()) {
      final rootType = await FileSystemEntity.type(
        buildCache.path,
        followLinks: false,
      );
      if (rootType == FileSystemEntityType.link) {
        _output('  ℹ️  Preserved linked .oka_cache/ for safety');
      } else if (rootType == FileSystemEntityType.directory) {
        final removed = await _cleanCacheDirectory(
          buildCache,
          protection.paths,
        );
        _output(
          removed
              ? '  ✅ Cleaned unrelated .oka_cache/ contents'
              : '  ℹ️  No unrelated .oka_cache/ contents to clean',
        );
        if (_hasProtectedOverlap(buildCache.path, protection.paths)) {
          _output('  ℹ️  Preserved protected session-state under .oka_cache/');
        }
      } else {
        _output('  ℹ️  Preserved non-directory .oka_cache/ for safety');
      }
    } else {
      _output('  ℹ️  .oka_cache/ not found');
    }

    // Clean full cache (including dependencies)
    if (results['full'] as bool) {
      _output('\n🧹 Cleaning dependency cache...');
      final home = _environment['HOME'] ?? '';
      final depCache = Directory(p.join(home, '.oka_cache', 'maven'));

      final type = await FileSystemEntity.type(
        depCache.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        final removed = await _cleanCacheDirectory(depCache, protection.paths);
        _output(
          removed
              ? '  ✅ Cleaned unrelated ~/.oka_cache/maven/ contents'
              : '  ℹ️  No unrelated ~/.oka_cache/maven/ contents to clean',
        );
        if (_hasProtectedOverlap(depCache.path, protection.paths)) {
          _output(
            '  ℹ️  Preserved protected session-state in dependency cache',
          );
        }
      } else if (type == FileSystemEntityType.link) {
        _output('  ℹ️  Preserved linked ~/.oka_cache/maven/ for safety');
      } else {
        _output('  ℹ️  ~/.oka_cache/maven/ not found');
      }
    }

    // Clean AI cache
    if (results['ai-cache'] as bool) {
      _output('\n🧹 Cleaning AI conversion cache...');
      final home = _environment['HOME'] ?? '';
      final aiCache = Directory(p.join(home, '.oka_cache', 'ai'));

      final type = await FileSystemEntity.type(
        aiCache.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        final removed = await _cleanCacheDirectory(aiCache, protection.paths);
        _output(
          removed
              ? '  ✅ Cleaned unrelated ~/.oka_cache/ai/ contents'
              : '  ℹ️  No unrelated ~/.oka_cache/ai/ contents to clean',
        );
        if (_hasProtectedOverlap(aiCache.path, protection.paths)) {
          _output('  ℹ️  Preserved protected session-state in AI cache');
        }
      } else if (type == FileSystemEntityType.link) {
        _output('  ℹ️  Preserved linked ~/.oka_cache/ai/ for safety');
      } else {
        _output('  ℹ️  ~/.oka_cache/ai/ not found');
      }
    }

    _output('\n✅ Clean complete!');
  }

  Future<_SessionStateCleanupProtection>
  _sessionStateCleanupProtection() async {
    final blockers = <String>[];
    final paths = <String>[];
    final SessionStateRegistrySnapshot snapshot;
    try {
      snapshot = await _inspectSessionStates();
    } on Object catch (error) {
      return _SessionStateCleanupProtection(
        blockers: ['Could not inspect session-state registry: $error'],
        paths: const [],
      );
    }
    blockers.addAll(
      snapshot.issues.map(
        (issue) =>
            'Session-state registry issue at ${issue.path}: ${issue.message}',
      ),
    );
    for (final lease in snapshot.leases) {
      if (lease.phase == SessionStatePhase.disposed ||
          lease.resourceKind != SessionStateResourceKind.directory) {
        continue;
      }
      final path = sessionStateDirectoryPath(lease);
      if (path == null) {
        blockers.add(
          'Could not safely resolve registered session-state resource '
          '"${lease.id}".',
        );
      } else {
        paths.add(path);
      }
      if (lease.quarantineRelativePath != null) {
        final quarantinePath = await sessionStateQuarantinePath(lease);
        if (quarantinePath == null) {
          blockers.add(
            'Could not safely resolve quarantine path for session-state '
            '"${lease.id}".',
          );
        } else {
          paths.add(quarantinePath);
        }
      }
      final reservationPath = sessionStateReservationMarkerPath(lease);
      if (reservationPath == null) {
        blockers.add(
          'Could not safely resolve reservation marker for session-state '
          '"${lease.id}".',
        );
      } else {
        paths.add(reservationPath);
        // Reservation records are durable registry evidence. Preserve the
        // directory, not only markers represented by the current snapshot.
        paths.add(p.dirname(reservationPath));
      }
    }
    return _SessionStateCleanupProtection(blockers: blockers, paths: paths);
  }

  Future<bool> _cleanCacheContents(
    Directory directory,
    List<String> protectedPaths,
  ) async {
    var removed = false;
    final children = await directory.list(followLinks: false).toList();
    for (final child in children) {
      final childPath = p.normalize(p.absolute(child.path));
      final overlapsProtection = protectedPaths.any(
        (path) => _pathsOverlap(childPath, path),
      );
      if (overlapsProtection) {
        final protectsDescendant = protectedPaths.any(
          (path) =>
              !p.equals(childPath, p.normalize(p.absolute(path))) &&
              p.isWithin(childPath, p.normalize(p.absolute(path))),
        );
        if (protectsDescendant &&
            await FileSystemEntity.type(child.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          removed =
              await _cleanCacheContents(
                Directory(child.path),
                protectedPaths,
              ) ||
              removed;
          if (await Directory(child.path).exists() &&
              await Directory(child.path).list().isEmpty) {
            await Directory(child.path).delete();
            removed = true;
          }
        }
        continue;
      }

      final type = await FileSystemEntity.type(child.path, followLinks: false);
      removed = await _deleteWithoutFollowingLinks(child.path, type) || removed;
    }
    return removed;
  }

  Future<bool> _cleanCacheDirectory(
    Directory directory,
    List<String> protectedPaths,
  ) async {
    final root = p.normalize(p.absolute(directory.path));
    final protectedAncestor = protectedPaths.any((path) {
      final protected = p.normalize(p.absolute(path));
      return p.equals(protected, root) || p.isWithin(protected, root);
    });
    if (protectedAncestor) return false;

    var removed = await _cleanCacheContents(directory, protectedPaths);
    final protectedDescendant = protectedPaths.any(
      (path) => p.isWithin(root, p.normalize(p.absolute(path))),
    );
    if (!protectedDescendant &&
        await directory.exists() &&
        await directory.list().isEmpty) {
      await directory.delete();
      removed = true;
    }
    return removed;
  }

  Future<bool> _deleteWithoutFollowingLinks(
    String path,
    FileSystemEntityType type,
  ) async {
    if (type == FileSystemEntityType.directory) {
      final directory = Directory(path);
      await for (final child in directory.list(followLinks: false)) {
        final childType = await FileSystemEntity.type(
          child.path,
          followLinks: false,
        );
        await _deleteWithoutFollowingLinks(child.path, childType);
      }
      await directory.delete();
      return true;
    }
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
      return true;
    }
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
      return true;
    }
    return false;
  }
}

final class _SessionStateCleanupProtection {
  const _SessionStateCleanupProtection({
    required this.blockers,
    required this.paths,
  });

  final List<String> blockers;
  final List<String> paths;
}

bool _pathsOverlap(String first, String second) {
  final a = p.normalize(p.absolute(first));
  final b = p.normalize(p.absolute(second));
  return p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
}

bool _hasProtectedOverlap(String path, List<String> protectedPaths) =>
    protectedPaths.any((protected) => _pathsOverlap(path, protected));
