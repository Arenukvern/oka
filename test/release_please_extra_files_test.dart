import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Mirrors `tool/release/train.dart` `packages` (publishable train).
const trainPackageNames = {
  'oka_process',
  'resource_composition',
  'oka_artifacts',
  'oka_core',
  'oka_supervisor',
  'oka_conformance',
  'oka_android',
  'oka_huawei',
  'oka_play',
  'oka_rustore',
  'oka_web',
  'oka_harness',
  'oka',
};

void main() {
  final root = Directory.current.path;
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
      final name = RegExp(r'^name:\s*(\S+)', multiLine: true)
          .firstMatch(file.readAsStringSync())
          ?.group(1);
      if (name == null || trainPackageNames.contains(name)) continue;
      final versionLine = RegExp(
        r'^version:[^\n]*x-release-please-version',
        multiLine: true,
      );
      if (versionLine.hasMatch(file.readAsStringSync())) {
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
