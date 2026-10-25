/// A throwaway workspace for the oka_verify tests: a root with a
/// `package_config.json` and the packages the lane resolves against.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A fixture workspace on disk.
final class Fixture {
  /// Creates an empty workspace root.
  factory Fixture.create() {
    final root = Directory.systemTemp.createTempSync('oka-verify-');
    return Fixture._(root);
  }

  Fixture._(this.root);

  /// The workspace root.
  final Directory root;

  /// The absolute path of [relativePath] inside the workspace.
  String path(String relativePath) => p.join(root.path, relativePath);

  /// Writes [content] at [relativePath] (creating parents).
  String write(String relativePath, String content) {
    final file = File(path(relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file.path;
  }

  /// Registers packages in the workspace `package_config.json`.
  ///
  /// [packages] maps a package name to its directory relative to the root.
  void writePackageConfig(Map<String, String> packages) {
    final file = File(path(p.join('.dart_tool', 'package_config.json')));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final entry in packages.entries)
            {
              'name': entry.key,
              'rootUri': '../${entry.value}',
              'packageUri': 'lib/',
              'languageVersion': '3.13',
            },
        ],
      }),
    );
  }

  /// Registers a package plus every package the current process resolved.
  ///
  /// The inherited entries are absolute-ized against their original
  /// configuration directory: the fixture lives elsewhere, so a relative
  /// `rootUri` would point at a nonexistent path.
  void writeWorkspacePackageConfig(String packageName, String packageRoot) {
    final inherited = _inheritedPackages();
    final packages = <Map<String, Object?>>[
      for (final entry in inherited?.packages ?? const <Map<String, Object?>>[])
        _absolutize(entry, inherited?.dir ?? root.path),
      <String, Object?>{
        'name': packageName,
        'rootUri': Uri.directory(packageRoot).toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      },
    ];
    final file = File(path(p.join('.dart_tool', 'package_config.json')));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': packages}),
    );
  }

  static Map<String, Object?> _absolutize(
    Map<String, Object?> entry,
    String configDir,
  ) {
    final value = entry['rootUri'];
    if (value is! String) return entry;
    return entry
      ..['rootUri'] = Uri.parse(value).isAbsolute
          ? value
          : Uri.directory('$configDir/')
              .resolveUri(Uri.parse(value))
              .toString();
  }

  /// The package configuration the current process resolved, if any.
  static ({List<Map<String, Object?>> packages, String dir})?
      _inheritedPackages() {
    var directory = Directory.current.absolute;
    while (true) {
      final candidate = File(
        p.join(directory.path, '.dart_tool', 'package_config.json'),
      );
      if (candidate.existsSync()) {
        final decoded = jsonDecode(candidate.readAsStringSync());
        if (decoded is! Map<String, Object?>) return null;
        final packages = decoded['packages'];
        if (packages is! List<Object?>) return null;
        return (
          packages: [
            for (final entry in packages)
              if (entry is Map<String, Object?>) entry,
          ],
          dir: candidate.parent.path,
        );
      }
      final parent = directory.parent;
      if (parent.path == directory.path) return null;
      directory = parent;
    }
  }

  /// Removes the workspace from disk.
  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
