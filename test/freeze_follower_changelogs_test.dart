import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/repo_root.dart';

void main() {
  final repo = findOkaRepoRoot();

  test('freeze --apply does not grow a trailing blank line on each run', () {
    final fixture = Directory.systemTemp.createTempSync('oka_freeze_eof_');
    try {
      _copyFollowerChangelogs(fixture, repo);
      final changelog = File('${fixture.path}/packages/oka_core/CHANGELOG.md');
      changelog.writeAsStringSync(_changelogWithFrozenTail(
        marked: '0.10.1',
        upcomingBullet: '- upcoming note',
        frozenVersion: '0.10.0',
        frozenBullet: '- prior release bullet',
        trailingNewline: true,
      ));
      _copyFreezeTooling(fixture, repo);
      final first = _runApply(fixture, released: '0.10.1', next: '0.11.0');
      expect(first.exitCode, 0, reason: _out(first));
      final afterFirst = changelog.readAsBytesSync();
      final firstText = utf8.decode(afterFirst);
      expect(firstText.endsWith('\n'), isTrue);
      expect(firstText.endsWith('\n\n'), isFalse);

      final second = _runApply(fixture, released: '0.10.1', next: '0.11.0');
      expect(second.exitCode, 0, reason: _out(second));
      final afterSecond = changelog.readAsBytesSync();
      expect(afterSecond, afterFirst);
      expect(RegExp(r'\n\n$').hasMatch(utf8.decode(afterSecond)), isFalse);
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test(
    'freeze --apply adds exactly one EOF newline when input omits trailing newline',
    () {
      final fixture = Directory.systemTemp.createTempSync('oka_freeze_eof_input_');
      try {
        _copyFollowerChangelogs(fixture, repo);
        final changelog = File('${fixture.path}/packages/oka_core/CHANGELOG.md');
        changelog.writeAsStringSync(_changelogWithFrozenTail(
          marked: '0.10.1',
          upcomingBullet: '- upcoming note',
          frozenVersion: '0.10.0',
          frozenBullet: '- prior release bullet',
          trailingNewline: false,
        ));
        final inputBytes = changelog.readAsBytesSync();
        expect(inputBytes.isEmpty || inputBytes.last != 0x0a, isTrue);
        _copyFreezeTooling(fixture, repo);
        final run = _runApply(fixture, released: '0.10.1', next: '0.11.0');
        expect(run.exitCode, 0, reason: _out(run));
        final text = changelog.readAsStringSync();
        expect(text.endsWith('\n'), isTrue);
        expect(text.endsWith('\n\n'), isFalse);
        expect(RegExp(r'\n\n$').hasMatch(text), isFalse);
      } finally {
        fixture.deleteSync(recursive: true);
      }
    },
  );

  test('freeze --apply is safe to rerun after the layout is already frozen', () {
    final fixture = Directory.systemTemp.createTempSync('oka_freeze_changelog_');
    try {
      _copyFollowerChangelogs(fixture, repo);
      final changelog = File('${fixture.path}/packages/oka_core/CHANGELOG.md');
      changelog.writeAsStringSync(_changelogWithFrozenTail(
        marked: '0.11.0',
        upcomingBullet: '- in-flight note',
        frozenVersion: '0.10.0',
        frozenBullet: '- shipped earlier',
        trailingNewline: true,
      ));
      _copyFreezeTooling(fixture, repo);
      final first = _runApply(fixture, released: '0.11.0', next: '0.12.0');
      expect(first.exitCode, 0, reason: _out(first));
      final frozen = changelog.readAsStringSync();
      const see =
          'See `packages/oka/CHANGELOG.md` for train-wide release notes.';
      expect(frozen, contains('## 0.12.0 <!-- x-release-please-version -->'));
      expect(frozen, contains('## 0.11.0'));
      expect(frozen, isNot(contains('## 0.11.0 <!--')));
      final seeCount = see.allMatches(frozen).length;
      expect(seeCount, greaterThanOrEqualTo(2));
      expect(
        frozen.indexOf('## 0.11.0'),
        lessThan(frozen.indexOf(see, frozen.indexOf('## 0.11.0'))),
      );
      expect(frozen, isNot(contains('$see\n\n\n')));
      expect(frozen.endsWith('\n'), isTrue);
      expect(frozen.endsWith('\n\n'), isFalse);
      expect(RegExp(r'\n\n$').hasMatch(frozen), isFalse);

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

String _changelogWithFrozenTail({
  required String marked,
  required String upcomingBullet,
  required String frozenVersion,
  required String frozenBullet,
  required bool trailingNewline,
}) {
  const see =
      'See `packages/oka/CHANGELOG.md` for train-wide release notes.';
  final body = StringBuffer()
    ..writeln('## $marked <!-- x-release-please-version -->')
    ..writeln()
    ..writeln(see)
    ..writeln()
    ..writeln(upcomingBullet)
    ..writeln()
    ..writeln('## $frozenVersion')
    ..writeln()
    ..write(frozenBullet);
  if (trailingNewline) {
    body.writeln();
  }
  return body.toString();
}
