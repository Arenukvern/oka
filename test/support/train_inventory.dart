import 'dart:io';

import 'package:test/test.dart';

/// Parses `const packages = <String>[...]` from `tool/release/train.dart`.
Set<String> trainPackagesFromTool(String root) {
  final trainDart = File('$root/tool/release/train.dart');
  if (!trainDart.existsSync()) {
    fail('expected repo root with tool/release/train.dart');
  }
  final src = trainDart.readAsStringSync();
  final block = RegExp(
    r'const packages = <String>\[(.*?)\];',
    dotAll: true,
  ).firstMatch(src);
  if (block == null) {
    fail('train.dart: packages inventory not found');
  }
  return {
    for (final m in RegExp("'([^']+)'").allMatches(block.group(1)!)) m.group(1)!,
  };
}

/// Copies every train package `pubspec.yaml` from [repoRoot] into [fixture].
void stageTrainPackagePubspecs(Directory fixture, String repoRoot) {
  final packages = trainPackagesFromTool(repoRoot).toList()..sort();
  for (final package in packages) {
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
