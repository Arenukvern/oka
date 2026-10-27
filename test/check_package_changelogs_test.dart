import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('passes when oka lists VERSION and followers use train marker', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.0', okaHasVersion: true);
      final result = _runCheck(fixture);
      expect(result.exitCode, 0, reason: _output(result));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('passes for next VERSION when only oka changelog is bumped', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', okaHasVersion: true);
      final result = _runCheck(fixture);
      expect(result.exitCode, 0, reason: _output(result));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('fails when oka changelog omits VERSION', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.0', okaHasVersion: false);
      final result = _runCheck(fixture);
      expect(result.exitCode, isNot(0));
      expect(_output(result), contains('packages/oka/CHANGELOG.md'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('fails when follower lacks marker and version heading', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', okaHasVersion: true);
      File('${fixture.path}/packages/oka_core/CHANGELOG.md').writeAsStringSync(
        '## 0.9.0\n\n- stale train entry only\n',
      );
      final result = _runCheck(fixture);
      expect(result.exitCode, isNot(0));
      expect(_output(result), contains('oka_core'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });
}

ProcessResult _runCheck(Directory fixture) => Process.runSync(
  'bash',
  ['tool/release/check_package_changelogs.sh'],
  workingDirectory: fixture.path,
  environment: {'OKA_ROOT': fixture.path},
);

String _output(ProcessResult result) => '${result.stdout}\n${result.stderr}';

void _writeTrainFixture(
  Directory fixture, {
  required String version,
  required bool okaHasVersion,
}) {
  final root = fixture.path;
  final repositoryRoot = Directory.current.path;
  File('$root/VERSION').writeAsStringSync('$version\n');
  for (final script in ['check_package_changelogs.sh', 'train.dart']) {
    final source = File('$repositoryRoot/tool/release/$script');
    File('$root/tool/release/$script')
      ..createSync(recursive: true)
      ..writeAsStringSync(source.readAsStringSync());
  }

  const marker = '<!-- oka-train-changelog: packages/oka/CHANGELOG.md -->';
  const trainPackages = [
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
  ];

  for (final package in trainPackages) {
    final dir = Directory('$root/packages/$package');
    dir.createSync(recursive: true);
    if (package == 'oka') {
      final heading = okaHasVersion ? '## [$version]' : '## [0.8.1]';
      File('${dir.path}/CHANGELOG.md').writeAsStringSync('$heading\n\n- notes\n');
      continue;
    }
    final body = '''
$marker

## 0.9.0

- Version aligned with the oka 0.9.0 train; see `packages/oka/CHANGELOG.md`.
''';
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(body);
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $package\n');
  }
}
