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
import 'dart:typed_data';

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
List<String> declaredAssetFiles(String projectRoot) =>
    _declaredUnder(projectRoot, 'assets:');

/// The fragment shader sources the app declares under
/// `flutter: shaders:` (`.frag`, project-root-relative). These are NOT
/// bundle assets: the build compiles each with impellerc and the
/// compiled bytes ride the bundle under the SOURCE's key —
/// `FragmentProgram.fromAsset('shaders/foo.frag')` takes the source
/// path. The dev session watches the sources and recompiles on save
/// (flutter_tools' own hot reload does the same).
List<String> declaredShaderFiles(String projectRoot) =>
    _declaredUnder(projectRoot, 'shaders:');

List<String> _declaredUnder(String projectRoot, String section) {
  final pubspec = File('$projectRoot/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw AssetSpecException('no pubspec.yaml under $projectRoot');
  }
  final lines = pubspec.readAsLinesSync();
  // Minimal shape walk: the `flutter:` top-level key, then the named
  // list section (`- path` items at deeper indent). Everything else is
  // ignored.
  String? stripComment(String l) {
    final i = l.indexOf('#');
    return i < 0 ? l : l.substring(0, i);
  }
  var inFlutter = false;
  var inSection = false;
  final files = <String>{};
  for (final raw in lines) {
    final line = stripComment(raw);
    if (line == null || line.trim().isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent == 0) {
      inFlutter = line.trim() == 'flutter:';
      inSection = false;
      continue;
    }
    if (!inFlutter) continue;
    if (indent <= 2) {
      inSection = line.trim() == section;
      continue;
    }
    if (!inSection) continue;
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
          'pubspec declares `$section` entry `$path` but it does not exist '
          'under $projectRoot');
    }
  }
  return files.toList()..sort();
}

/// Compiles a `.frag` source with impellerc and returns the compiled
/// bytes that ride the bundle under the source's key — the exact
/// flutter_tools shape (`--iplr --sl=<out> --spirv=<out>.spirv`, plus
/// the platform's runtime stages: `--sksl --runtime-stage-metal` on
/// darwin; the `.spirv` side output is deleted after use). [flutterBin]
/// locates `bin/cache/artifacts/engine/<host>/impellerc` (+ its
/// `shader_lib` include dir).
Future<Uint8List> compileShader({
  required String fragPath,
  required String flutterBin,
}) async {
  final root = _flutterRoot(flutterBin);
  if (root == null) {
    throw AssetSpecException(
        'cannot locate the flutter SDK from `$flutterBin` — pass '
        '--flutter-bin');
  }
  String? impellerc;
  for (final host in _hostArtifactDirs()) {
    final candidate = '$root/bin/cache/artifacts/engine/$host/impellerc';
    if (File(candidate).existsSync()) {
      impellerc = candidate;
      break;
    }
  }
  if (impellerc == null) {
    throw AssetSpecException(
        'impellerc not found under $root/bin/cache/artifacts/engine — '
        'run `flutter doctor` (the shader tooling ships with the SDK)');
  }
  final work = Directory.systemTemp.createTempSync('oka-shader-');
  final out = '${work.path}/shader.iplr';
  final targets = Platform.isMacOS
      ? const ['--sksl', '--runtime-stage-metal']
      : const ['--sksl', '--runtime-stage-gles', '--runtime-stage-gles3'];
  try {
    final r = await Process.run(impellerc, [
      ...targets,
      '--iplr',
      '--sl=$out',
      '--spirv=$out.spirv',
      '--input=$fragPath',
      '--input-type=frag',
      '--include=${File(fragPath).parent.path}',
      '--include=${File(impellerc).parent.path}/shader_lib',
    ]);
    final file = File(out);
    if (r.exitCode != 0 || !file.existsSync()) {
      throw AssetSpecException('impellerc failed on $fragPath:\n'
          '${r.stdout}\n${r.stderr}');
    }
    return file.readAsBytesSync();
  } finally {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      // Temp cleanup is best-effort.
    }
  }
}

String? _flutterRoot(String flutterBin) {
  var bin = flutterBin;
  if (!bin.contains('/')) {
    final which = Process.runSync('which', [bin]);
    if (which.exitCode == 0) bin = (which.stdout as String).trim();
  }
  final fvmDefault =
      '${Platform.environment['HOME']}/fvm/default/bin/flutter';
  if (!File(bin).existsSync() && File(fvmDefault).existsSync()) {
    bin = fvmDefault;
  }
  final root = File(bin).parent.parent.path; // <flutter>/bin/flutter
  return Directory('$root/bin/cache').existsSync() ? root : null;
}

List<String> _hostArtifactDirs() => [
      if (Platform.isMacOS) ...['darwin-arm64', 'darwin-x64'],
      if (Platform.isLinux) ...['linux-x64', 'linux-arm64'],
      if (Platform.isWindows) 'windows-x64',
    ];

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
