import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Discovers directory storage without invoking platform package managers.
/// External caches and device data are always informational.
Future<List<StorageLocation>> discoverStorageLocations({
  required String projectPath,
  Map<String, String>? environment,
  String? hostPlatform,
  bool includeShared = true,
  bool includeProject = true,
  ProcessLiveness liveness = const HostProcessLiveness(),
}) async {
  final env = environment ?? Platform.environment;
  final host = hostPlatform ?? Platform.operatingSystem;
  final home = env['HOME'] ?? env['USERPROFILE'];
  final result = <StorageLocation>[];
  String expand(String path) => p.normalize(
    p.absolute(
      path.startsWith('~/') && home != null
          ? p.join(home, path.substring(2))
          : path,
    ),
  );
  Future<void> add(
    String rawPath,
    String category,
    String platform,
    String ownership, {
    String? scope,
    bool prunable = false,
    String? note,
  }) async {
    final path = expand(rawPath);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    final previous = result.indexWhere((location) => location.path == path);
    if (previous >= 0) {
      // A protected classification always wins over a cache override.
      if (!result[previous].prunable || prunable) return;
      result.removeAt(previous);
    }
    final link = type == FileSystemEntityType.link;
    result.add(
      StorageLocation(
        id: '$category:$path',
        path: path,
        category: category,
        platform: platform,
        ownership: ownership,
        scope: scope,
        prunable: prunable && !link,
        note: link ? 'Symbolic link; target is not scanned or pruned.' : note,
      ),
    );
  }

  Future<List<FileSystemEntity>> children(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return [];
    }
    try {
      return await Directory(path).list(followLinks: false).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      await add(
        path,
        'unreadable-storage',
        'all',
        'unknown',
        note:
            'Directory listing failed; storage is protected and scan may be incomplete.',
      );
      return [];
    }
  }

  if (includeProject) {
    final registry = ProcessLeaseRegistry.forProject(
      projectPath,
      liveness: liveness,
    );
    String? buildGuard;
    try {
      final snapshot = await registry.inspect();
      if (!snapshot.complete) {
        buildGuard =
            'Unreadable process leases; inspect oka processes list before pruning.';
      }
      for (final lease in snapshot.leases) {
        final state = await registry.checkLiveness(lease);
        if (state == LeaseLiveness.live || state == LeaseLiveness.unknown) {
          buildGuard =
              'Live or uncertain process lease; inspect oka processes list before pruning.';
          break;
        }
      }
    } on Object {
      buildGuard =
          'Unreadable process leases; inspect oka processes list before pruning.';
    }
    Future<bool> protectedDescendant(String path) async {
      for (final child in await children(path)) {
        if (p.basename(child.path) == 'chrome-profiles' ||
            p.basename(child.path) == 'processes') {
          return true;
        }
        if (child is Directory && await protectedDescendant(child.path)) {
          return true;
        }
      }
      return false;
    }

    Future<void> buildUnit(String path) async {
      final name = p.basename(path);
      if (name == 'chrome-profiles' || name == 'processes') {
        await add(
          path,
          name == 'chrome-profiles' ? 'browser-profiles' : 'process-leases',
          'all',
          'user',
          note: 'Persistent session data; preserved by cache prune.',
        );
      } else if (await protectedDescendant(path)) {
        for (final child in await children(path)) {
          await buildUnit(child.path);
        }
      } else {
        await add(
          path,
          'build-output',
          'all',
          'oka',
          scope: 'build',
          prunable: buildGuard == null,
          note: buildGuard,
        );
      }
    }

    final projectCache = p.join(projectPath, '.oka_cache');
    if (await FileSystemEntity.type(projectCache, followLinks: false) ==
        FileSystemEntityType.link) {
      await add(projectCache, 'project-state', 'all', 'user');
    } else {
      for (final child in await children(projectCache)) {
        if (p.basename(child.path) == 'build' && child is Directory) {
          for (final mode in await children(child.path)) {
            await buildUnit(mode.path);
          }
        } else {
          await add(
            child.path,
            p.basename(child.path) == 'chrome-profiles'
                ? 'browser-profiles'
                : 'project-state',
            'all',
            'user',
            note: 'Persistent or unrecognized project state; preserved.',
          );
        }
      }
    }
  }
  if (!includeShared) return result;
  final store = LocalArtifactStore.defaultRoot(environment: env);
  final storeChildren = await children(store);
  if (storeChildren.isEmpty) {
    await add(
      store,
      'shared-cache',
      'all',
      'oka',
      scope: 'shared',
      prunable: true,
    );
  } else {
    for (final child in storeChildren) {
      await add(
        child.path,
        'shared-${p.basename(child.path)}',
        'all',
        'oka',
        scope: 'shared',
        prunable: true,
      );
    }
  }
  // Split known container layouts into independently useful informational units.
  Future<void> reportUnits(
    String path,
    String category,
    String platform,
    String ownership,
    int depth,
    String guidance,
  ) async {
    final parts = depth > 0 ? await children(path) : <FileSystemEntity>[];
    if (parts.isEmpty) {
      await add(
        path,
        category,
        platform,
        ownership,
        note: '${p.basename(path)}; $guidance',
      );
      return;
    }
    // Replace a previously discovered cache alias to this same container with
    // its protected children, preventing overlap and unsafe classification.
    result.removeWhere(
      (location) => location.path == expand(path) && location.prunable,
    );
    for (final part in parts) {
      await reportUnits(
        part.path,
        category,
        platform,
        ownership,
        depth - 1,
        guidance,
      );
    }
  }

  Future<void> sdk(String path, String ownership) async {
    final parts = await children(path);
    if (parts.isEmpty) {
      await add(
        path,
        'android-sdk',
        'android',
        ownership,
        note: 'Manage SDK packages with sdkmanager.',
      );
    }
    for (final part in parts) {
      if (p.basename(part.path) == 'system-images') {
        await reportUnits(
          part.path,
          'android-sdk-system-images',
          'android',
          ownership,
          3,
          'Manage this system image with sdkmanager; emulator images are not build caches.',
        );
        continue;
      }
      await add(
        part.path,
        'android-sdk-${p.basename(part.path)}',
        'android',
        ownership,
        note:
            'Manage SDK packages with sdkmanager; emulator images are not disposable build caches.',
      );
    }
  }

  if (home != null) {
    // The project registry is durable user metadata, even when OKA_CACHE
    // overlaps ~/.oka. Protected classifications override shared candidates.
    final registryPath = CacheProjectRegistry(environment: env).path;
    for (final metadata in [registryPath, '$registryPath.lock']) {
      await add(
        metadata,
        'project-registry',
        'all',
        'user',
        note: 'Known-project metadata; preserved by cache cleanup.',
      );
    }
    for (final legacy in [
      '.oka/cache/maven',
      '.oka_cache/maven',
      '.oka_cache/ai',
    ]) {
      await add(
        p.join(home, legacy),
        'legacy-cache',
        'all',
        'oka',
        scope: 'shared',
        prunable: true,
      );
    }
    await add(
      p.join(home, '.oka', 'tools'),
      'tools',
      'all',
      'oka',
      scope: 'tools',
      prunable: true,
    );
    await sdk(p.join(home, '.oka', 'android-sdk'), 'oka');
  }
  for (final key in ['OKA_ANDROID_SDK', 'ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    if (env[key]?.isNotEmpty ?? false) await sdk(expand(env[key]!), 'external');
  }
  final avdRoots = <String>{
    if (home != null) p.join(home, '.android', 'avd'),
    if (env['ANDROID_AVD_HOME']?.isNotEmpty ?? false)
      expand(env['ANDROID_AVD_HOME']!),
    if (env['ANDROID_USER_HOME']?.isNotEmpty ?? false)
      p.join(expand(env['ANDROID_USER_HOME']!), 'avd'),
  };
  for (final root in avdRoots) {
    for (final child in await children(root)) {
      final name = p.basenameWithoutExtension(child.path);
      await add(
        child.path,
        'android-virtual-device',
        'android',
        'user',
        note:
            '$name; manage with Android Studio Device Manager or avdmanager. Disk bytes may differ for sparse images; running status is not inferred.',
      );
      if (child is File && child.path.endsWith('.ini')) {
        try {
          for (final line in await child.readAsLines()) {
            if (line.startsWith('path=')) {
              await add(
                line.substring(5).trim(),
                'android-virtual-device',
                'android',
                'user',
                note:
                    '$name; custom AVD location. Manage with Android Studio Device Manager or avdmanager.',
              );
            }
          }
        } on FileSystemException {
          /* Directory measurement reports unreadable data. */
        }
      }
    }
  }
  if (host == 'macos') {
    for (final root in [
      if (home != null) p.join(home, 'Library/Developer/CoreSimulator/Devices'),
      if (home != null)
        p.join(home, 'Library/Developer/CoreSimulator/Profiles/Runtimes'),
      '/Library/Developer/CoreSimulator/Profiles/Runtimes',
      '/Library/Developer/CoreSimulator/Images',
    ]) {
      await reportUnits(
        root,
        root.endsWith('Devices')
            ? 'apple-simulator-devices'
            : 'apple-simulator-runtimes',
        'apple',
        'user',
        1,
        'Manage devices with xcrun simctl and runtimes through Xcode Settings > Components. Running status is not inferred.',
      );
    }
  }
  final pub =
      env['PUB_CACHE'] ??
      (home == null
          ? null
          : host == 'windows'
          ? p.join(
              env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local'),
              'Pub',
              'Cache',
            )
          : p.join(home, '.pub-cache'));
  if (pub != null) {
    await add(
      pub,
      'dart-pub-cache',
      'all',
      'external',
      note: 'Manage with dart pub cache clean; shared with other projects.',
    );
  }
  if (env['FLUTTER_ROOT']?.isNotEmpty ?? false) {
    await add(
      p.join(expand(env['FLUTTER_ROOT']!), 'bin', 'cache'),
      'flutter-sdk-cache',
      'all',
      'external',
      note:
          'Flutter-managed engine and platform artifacts; shared with other projects.',
    );
  }
  return result;
}
