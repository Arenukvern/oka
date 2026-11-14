import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/repo_root.dart';

/// Parses `const packages = <String>[...]` from [tool/release/train.dart].
/// Fails the test when not run from the repo root (no subprocess / no CLI).
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

void main() {
  final root = findOkaRepoRoot();
  late Set<String> trainPackageNames;

  setUpAll(() {
    trainPackageNames = trainPackagesFromTool(root);
    expect(trainPackageNames, isNotEmpty);
  });

  final config = jsonDecode(
    File('$root/release-please-config.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final extra =
      (((config['packages'] as Map)['.'] as Map)['extra-files'] as List)
          .cast<Map<String, dynamic>>();

  test('non-train pubspec extra-files do not mark own version for release-please',
      () {
    final genericPubspecs = extra
        .where((e) => e['type'] == 'generic')
        .map((e) => e['path'] as String)
        .where((p) => p.startsWith('packages/') && p.endsWith('/pubspec.yaml'));
    final violations = <String>[];
    for (final relative in genericPubspecs) {
      final file = File('$root/$relative');
      expect(file.existsSync(), isTrue, reason: relative);
      final contents = file.readAsStringSync();
      final name = RegExp(r'^name:\s*(\S+)', multiLine: true)
          .firstMatch(contents)
          ?.group(1);
      if (name == null || trainPackageNames.contains(name)) continue;
      if (RegExp(
        r'^version:[^\n]*x-release-please-version',
        multiLine: true,
      ).hasMatch(contents)) {
        violations.add(relative);
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'release-please would bump non-train package versions: '
          '${violations.join(', ')}',
    );
  });

  test('workspace-only extra pubspecs still mark train dependencies', () {
    for (final path in [
      'packages/oka_dart_kernel/pubspec.yaml',
      'packages/oka_verify/pubspec.yaml',
    ]) {
      final contents = File('$root/$path').readAsStringSync();
      expect(
        contents,
        matches(RegExp(r'oka_core:\s*\^[0-9.]+\s*#\s*x-release-please-version')),
        reason: '$path must keep train dep marker for release-please',
      );
    }
  });
}
