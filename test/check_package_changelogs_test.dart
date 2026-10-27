import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('passes when every train package lists VERSION in CHANGELOG', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', allHaveVersion: true);
      final result = _runCheck(fixture);
      expect(result.exitCode, 0, reason: _output(result));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('fails when a follower omits VERSION heading', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', allHaveVersion: true);
      File('${fixture.path}/packages/oka_core/CHANGELOG.md').writeAsStringSync(
        '## 0.9.0 <!-- x-release-please-version -->\n\n- stale\n',
      );
      final result = _runCheck(fixture);
      expect(result.exitCode, isNot(0));
      expect(_output(result), contains('oka_core'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('accepts release-please heading with inline version annotation', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', allHaveVersion: true);
      final result = _runCheck(fixture);
      expect(result.exitCode, 0, reason: _output(result));
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
  required bool allHaveVersion,
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
    final heading = package == 'oka'
        ? '## [$version]'
        : '## $version <!-- x-release-please-version -->';
    final versionLine = allHaveVersion || package == 'oka';
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(
      versionLine
          ? '$heading\n\nSee `packages/oka/CHANGELOG.md`.\n'
          : '## 0.9.0 <!-- x-release-please-version -->\n\n- stale\n',
    );
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $package\n');
  }
}
