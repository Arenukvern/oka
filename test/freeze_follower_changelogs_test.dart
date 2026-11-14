import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/repo_root.dart';

void main() {
  final repo = findOkaRepoRoot();

  test('freeze --apply is safe to rerun after the layout is already frozen', () {
    final fixture = Directory.systemTemp.createTempSync('oka_freeze_changelog_');
    try {
      _copyFollowerChangelogs(fixture, repo);
      final changelog = File('${fixture.path}/packages/oka_core/CHANGELOG.md');
      changelog.writeAsStringSync(
        '## 0.11.0 <!-- x-release-please-version -->\n\n'
        'See `packages/oka/CHANGELOG.md` for train-wide release notes.\n\n'
        '- in-flight note\n',
      );
      _copyFreezeTooling(fixture, repo);
      final first = _runApply(fixture, released: '0.11.0', next: '0.12.0');
      expect(first.exitCode, 0, reason: _out(first));
      final frozen = changelog.readAsStringSync();
      expect(frozen, contains('## 0.12.0 <!-- x-release-please-version -->'));
      expect(frozen, contains('## 0.11.0'));
      expect(frozen, isNot(contains('## 0.11.0 <!--')));

      final second = _runApply(fixture, released: '0.11.0', next: '0.12.0');
      expect(second.exitCode, 0, reason: _out(second));
      expect(changelog.readAsStringSync(), frozen);
      expect(_out(second), contains('updated 0 follower'));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });
}

void _copyFollowerChangelogs(Directory fixture, String repo) {
  _copyFreezeTooling(fixture, repo);
  final config =
      jsonDecode(
            File('${fixture.path}/release-please-config.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final packages = config['packages'] as Map<String, dynamic>;
  final dot = packages['.'] as Map<String, dynamic>;
  final extra = dot['extra-files'] as List<dynamic>;
  for (final entry in extra) {
    final map = entry as Map<String, dynamic>;
    final path = map['path'] as String;
    if (!path.endsWith('/CHANGELOG.md')) continue;
    final source = File('$repo/$path');
  final dest = File('${fixture.path}/$path')..createSync(recursive: true);
    dest.writeAsStringSync(
      source.existsSync()
          ? source.readAsStringSync()
          : '## 0.11.0 <!-- x-release-please-version -->\n\n'
                'See `packages/oka/CHANGELOG.md` for train-wide release notes.\n',
    );
  }
}

void _copyFreezeTooling(Directory fixture, String repo) {
  for (final name in [
    'freeze_follower_changelogs.dart',
    'semver_tool.dart',
  ]) {
    final source = File('$repo/tool/release/$name');
    File('${fixture.path}/tool/release/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(source.readAsStringSync());
  }
  final config = File('$repo/release-please-config.json');
  File('${fixture.path}/release-please-config.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(config.readAsStringSync());
}

ProcessResult _runApply(
  Directory fixture, {
  required String released,
  required String next,
}) => Process.runSync(
  'dart',
  [
    'tool/release/freeze_follower_changelogs.dart',
    '--apply',
    '--released',
    released,
    '--next',
    next,
  ],
  workingDirectory: fixture.path,
);

String _out(ProcessResult r) => '${r.stdout}\n${r.stderr}';
