import 'dart:io';

import 'package:test/test.dart';

import '../tool/release/train_inventory.dart';
import 'support/repo_root.dart';

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

  test('fails when a follower omits the VERSION heading', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.9.1', allHaveVersion: true);
      File('${fixture.path}/packages/oka_core/CHANGELOG.md').writeAsStringSync(
        '## 0.9.2\n\n'
        'See `packages/oka/CHANGELOG.md`.\n\n'
        '## 0.9.0\n\n- stale\n',
      );
      final result = _runCheck(fixture);
      expect(result.exitCode, isNot(0));
      expect(_output(result), contains('oka_core'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('does not accept lookalike headings when dots are not literal', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.10.0', allHaveVersion: true);
      // Only the lookalike exists — the version regex must not match it.
      File('${fixture.path}/packages/oka_core/CHANGELOG.md').writeAsStringSync(
        '## 0a10a0\n\n'
        'See `packages/oka/CHANGELOG.md`.\n',
      );
      final result = _runCheck(fixture);
      expect(result.exitCode, isNot(0));
      expect(_output(result), contains('oka_core'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('accepts annotated headings when the version is present '
      '(the marker law is retired — ADR-0054)', () {
    final fixture = Directory.systemTemp.createTempSync('oka_pkg_changelog_');
    try {
      _writeTrainFixture(fixture, version: '0.11.0', allHaveVersion: true);
      File('${fixture.path}/packages/oka_core/CHANGELOG.md').writeAsStringSync(
        '## 0.11.0 <!-- x-release-please-version -->\n\n'
        'See `packages/oka/CHANGELOG.md` for train-wide release notes.\n\n'
        '## 0.10.0\n\n'
        '- Dependency lockfile hygiene (`fix: locks`).\n',
      );
      final result = _runCheck(fixture);
      expect(result.exitCode, 0, reason: _output(result));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('accepts frozen follower layout with upcoming marker heading', () {
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

String _nextPatch(String version) {
  final parts = version.split('.');
  final patch = int.parse(parts[2]) + 1;
  return '${parts[0]}.${parts[1]}.$patch';
}

void _writeTrainFixture(
  Directory fixture, {
  required String version,
  required bool allHaveVersion,
}) {
  final root = fixture.path;
  final repositoryRoot = findOkaRepoRoot();
  File('$root/VERSION').writeAsStringSync('$version\n');
  for (final script in [
    'check_package_changelogs.sh',
    'train.dart',
    'train_inventory.dart',
    'publish_order.dart',
    'semver_tool.dart',
  ]) {
    final source = File('$repositoryRoot/tool/release/$script');
    File('$root/tool/release/$script')
      ..createSync(recursive: true)
      ..writeAsStringSync(source.readAsStringSync());
  }

  final next = _nextPatch(version);

  for (final package in packages) {
    final dir = Directory('$root/packages/$package');
    dir.createSync(recursive: true);
    final versionLine = allHaveVersion || package == 'oka';
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(
      package == 'oka'
          ? '## [$version]\n\n- primary\n'
          : versionLine
          ? '## $next <!-- x-release-please-version -->\n\n'
                'See `packages/oka/CHANGELOG.md` for train-wide release notes.\n\n'
                '## $version\n\n'
                '- package notes\n'
          : '## 0.9.0 <!-- x-release-please-version -->\n\n- stale\n',
    );
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $package\n');
  }
}
