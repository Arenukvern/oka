import 'dart:io';

import 'package:path/path.dart' as p;

/// Generated, vendored, or tool dirs skipped on every contract tree walk.
const contractGeneratedSkipDirNames = <String>{
  '.git',
  '.dart_tool',
  'build',
  '.pub-cache',
  'node_modules',
  '.idea',
  '.vscode',
  'dist',
  'coverage',
  '.gradle',
  '.symlinks',
  'Pods',
  'ephemeral',
  'Flutter',
};

/// Flutter platform embedding dirs — skipped only when hunting pubspecs.
const contractPlatformSkipDirNames = <String>{
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
  'web',
};

final Set<String> contractPubspecSkipDirNames = {
  ...contractGeneratedSkipDirNames,
  ...contractPlatformSkipDirNames,
};

bool shouldSkipContractScanPath(
  String absolutePath,
  Directory root, {
  required Set<String> skipDirNames,
}) {
  final rel = p.relative(absolutePath, from: root.path).replaceAll(r'\', '/');
  for (final segment in rel.split('/')) {
    if (skipDirNames.contains(segment)) return true;
  }
  return false;
}

/// Depth-first file walk under [root]; never follows symlinks.
Iterable<File> contractScanFiles(
  Directory root, {
  required bool Function(File file) select,
  Set<String> skipDirNames = contractGeneratedSkipDirNames,
}) sync* {
  if (!root.existsSync()) return;
  for (final entity in root.listSync(followLinks: false)) {
    if (entity is Link) continue;
    if (entity is Directory) {
      if (shouldSkipContractScanPath(entity.path, root, skipDirNames: skipDirNames)) {
        continue;
      }
      yield* contractScanFiles(
        entity,
        select: select,
        skipDirNames: skipDirNames,
      );
    } else if (entity is File && select(entity)) {
      yield entity;
    }
  }
}

Iterable<File> contractPubspecFiles(Directory root) sync* {
  yield* contractScanFiles(
    root,
    select: (f) => p.basename(f.path) == 'pubspec.yaml',
    skipDirNames: contractPubspecSkipDirNames,
  );
}
