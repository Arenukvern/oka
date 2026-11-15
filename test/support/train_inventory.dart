import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release/train_inventory.dart';

/// Train package names from [packages] (tool/release/train_inventory.dart).
Set<String> trainPackagesFromTool(String root) => packages.toSet();

/// Copies every train package `pubspec.yaml` from [repoRoot] into [fixture].
void stageTrainPackagePubspecs(Directory fixture, String repoRoot) {
  final names = packages.toList()..sort();
  for (final package in names) {
    final srcPubspec = File('$repoRoot/packages/$package/pubspec.yaml');
    expect(
      srcPubspec.existsSync(),
      isTrue,
      reason: 'missing packages/$package/pubspec.yaml in repo',
    );
    final dstDir = Directory('${fixture.path}/packages/$package')
      ..createSync(recursive: true);
    File('${dstDir.path}/pubspec.yaml').writeAsStringSync(
      srcPubspec.readAsStringSync(),
    );
  }
}
