import 'dart:io';

import 'package:path/path.dart' as p;

/// Directory names skipped when contract gates walk the repo tree.
const contractScanSkipDirNames = <String>{
  '.git',
  '.dart_tool',
  'build',
  '.pub-cache',
  'node_modules',
  '.idea',
  '.vscode',
  'dist',
  'coverage',
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
  'web',
  '.gradle',
  '.symlinks',
  'Pods',
  'ephemeral',
  'Flutter',
};

bool shouldSkipContractScanPath(String absolutePath, Directory root) {
  final rel = p.relative(absolutePath, from: root.path).replaceAll(r'\', '/');
  for (final segment in rel.split('/')) {
    if (contractScanSkipDirNames.contains(segment)) return true;
  }
  return false;
}

/// Depth-first file walk under [root]; never follows symlinks.
Iterable<File> contractScanFiles(
  Directory root, {
  required bool Function(File file) select,
}) sync* {
  if (!root.existsSync()) return;
  for (final entity in root.listSync()) {
    if (entity is Directory) {
      if (shouldSkipContractScanPath(entity.path, root)) continue;
      yield* contractScanFiles(entity, select: select);
    } else if (entity is File && select(entity)) {
      yield entity;
    }
  }
}

Iterable<File> contractPubspecFiles(Directory root) sync* {
  yield* contractScanFiles(
    root,
    select: (f) => p.basename(f.path) == 'pubspec.yaml',
  );
}
