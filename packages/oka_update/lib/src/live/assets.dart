/// Dev-session asset sync (ADR-0037 §6, G-RUN): where a debug desktop
/// app's assets live and which files the app declares. The sync itself
/// (write bytes into the engine's asset dir + `ext.flutter.evict`) rides
/// the target; these are the pure discovery halves.
///
/// Wire facts (measured, flutter 3.47 / macOS):
/// - The debug engine reads assets from the build product's
///   `App.framework/Versions/A/Resources/flutter_assets` — NOT from
///   flutter_tools' DevFS dir (which the engine never receives) and not
///   from any server: a plain host directory the session can write.
/// - After a write + `ext.flutter.evict`, the engine still serves the
///   previously-mapped bytes (engine-level asset cache): live freshness
///   is engine-blocked on macOS today — the next engine cycle (`R`)
///   picks the synced bytes up. flutter's own desktop asset hot reload
///   has the same ceiling.
library;

import 'dart:io';

/// Exception naming the fix (missing pubspec section, unexpected shape).
class AssetSpecException implements Exception {
  AssetSpecException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The asset files the app declares in `pubspec.yaml` under
/// `flutter: assets:` — file entries as-is, directory entries expanded
/// recursively (sorted, project-root-relative). Non-dart files only make
/// sense here, but the declaration is trusted: whatever pubspec lists is
/// what the dev session watches.
List<String> declaredAssetFiles(String projectRoot) {
  final pubspec = File('$projectRoot/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw AssetSpecException('no pubspec.yaml under $projectRoot');
  }
  final lines = pubspec.readAsLinesSync();
  // Minimal shape walk: the `flutter:` top-level key, then its `assets:`
  // list (`- path` items at deeper indent). Everything else is ignored.
  String? stripComment(String l) {
    final i = l.indexOf('#');
    return i < 0 ? l : l.substring(0, i);
  }
  var inFlutter = false;
  var inAssets = false;
  final files = <String>{};
  for (final raw in lines) {
    final line = stripComment(raw);
    if (line == null || line.trim().isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent == 0) {
      inFlutter = line.trim() == 'flutter:';
      inAssets = false;
      continue;
    }
    if (!inFlutter) continue;
    if (indent <= 2) {
      inAssets = line.trim() == 'assets:';
      continue;
    }
    if (!inAssets) continue;
    final entry = line.trim();
    if (!entry.startsWith('- ')) continue;
    final path = entry.substring(2).trim();
    final abs = '$projectRoot/$path';
    if (Directory(abs).existsSync()) {
      files.addAll(Directory(abs)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path
              .substring('$projectRoot/'.length)
              .replaceAll(r'\', '/'))
          .where((p) => !p.endsWith('/')));
    } else if (File(abs).existsSync()) {
      files.add(path);
    } else {
      throw AssetSpecException(
          'pubspec declares asset `$path` but it does not exist under '
          '$projectRoot');
    }
  }
  return files.toList()..sort();
}

/// The flutter_assets directory a debug macOS build product exposes —
/// the newest `.app` under `build/macos/Build/Products/*/`, resolved
/// through the framework's versioned Resources (the engine's read path).
/// Null when the project has no macOS build yet.
String? findFlutterAssetsDir(String projectRoot) {
  final products = Directory('$projectRoot/build/macos/Build/Products');
  if (!products.existsSync()) return null;
  final candidates = <String>[];
  for (final mode in products.listSync()) {
    if (mode is! Directory) continue;
    for (final app in mode.listSync()) {
      if (app is! Directory || !app.path.endsWith('.app')) continue;
      final dir = '${app.path}/Contents/Frameworks/App.framework'
          '/Versions/A/Resources/flutter_assets';
      if (Directory(dir).existsSync()) candidates.add(dir);
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => Directory(b)
      .statSync()
      .modified
      .compareTo(Directory(a).statSync().modified));
  return candidates.first;
}
