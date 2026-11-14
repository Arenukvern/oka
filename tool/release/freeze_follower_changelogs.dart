#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

const marker = 'x-release-please-version';
const seeLine =
    'See `packages/oka/CHANGELOG.md` for train-wide release notes.';
final _seePattern = RegExp(
  r'^See `packages/oka/CHANGELOG\.md`(?: for train-wide release notes)?\.?\s*$',
);
final _versionHeading = RegExp(r'^## (\d+\.\d+\.\d+)(.*)$');
final _markedHeading = RegExp(
  r'^## (\d+\.\d+\.\d+) <!-- x-release-please-version -->$',
);

Directory _repoRoot() {
  final script = File(Platform.script.toFilePath());
  return script.parent.parent.parent;
}

List<String> _followerChangelogPaths(Directory root) {
  final configFile = File('${root.path}/release-please-config.json');
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final package = config['packages'] as Map<String, dynamic>;
  final dot = package['.'] as Map<String, dynamic>;
  final extra = dot['extra-files'] as List<dynamic>;
  return extra
      .whereType<Map<String, dynamic>>()
      .map((e) => e['path'] as String)
      .where((p) => p.endsWith('/CHANGELOG.md'))
      .toList()
    ..sort();
}

String _normalizeNewlines(String source) =>
    source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

bool _isVersionHeading(String line) => _versionHeading.hasMatch(line);

bool _applyFreeze({
  required File file,
  required String released,
  required String next,
  required bool dryRun,
}) {
  final raw = _normalizeNewlines(file.readAsStringSync());
  if (raw.isEmpty) throw FormatException('${file.path}: empty changelog');

  final lines = raw.split('\n');
  final markedIndex = lines.indexWhere(_markedHeading.hasMatch);
  if (markedIndex < 0) {
    final frozen = lines.indexWhere((l) => l == '## $released');
    final upcoming =
        lines.indexWhere((l) => l == '## $next <!-- $marker -->');
    if (frozen >= 0 && upcoming >= 0 && upcoming < frozen) {
      return false;
    }
    throw FormatException(
      '${file.path}: no marked heading to freeze (expected ## $released <!-- $marker -->)',
    );
  }

  final markedVersion = _markedHeading.firstMatch(lines[markedIndex])!.group(1)!;
  if (markedVersion == next) {
    final frozenIndex = lines.indexWhere((l) => l == '## $released');
    if (frozenIndex > markedIndex) return false;
  }

  var sectionEnd = lines.length;
  for (var i = markedIndex + 1; i < lines.length; i++) {
    if (_isVersionHeading(lines[i])) {
      sectionEnd = i;
      break;
    }
  }

  final preamble = lines.sublist(0, markedIndex);
  final sectionBody = lines.sublist(markedIndex + 1, sectionEnd);
  final tail = lines.sublist(sectionEnd);

  final frozenBody = <String>[];
  var skippingSee = true;
  for (final line in sectionBody) {
    if (skippingSee && line.trim().isEmpty) continue;
    if (skippingSee && _seePattern.hasMatch(line)) {
      skippingSee = false;
      continue;
    }
    skippingSee = false;
    frozenBody.add(line);
  }

  while (frozenBody.isNotEmpty && frozenBody.last.trim().isEmpty) {
    frozenBody.removeLast();
  }

  final out = <String>[
    ...preamble,
    '## $next <!-- $marker -->',
    '',
    seeLine,
    '',
    '## $released',
    if (frozenBody.isNotEmpty) ...['', ...frozenBody],
    if (tail.isNotEmpty) ...['', ...tail],
  ];

  final text = '${out.join('\n')}\n';
  if (text == raw) return false;
  if (!dryRun) file.writeAsStringSync(text);
  return true;
}

void _usage() {
  stderr.writeln(
    'Usage: freeze_follower_changelogs.dart [--check] | '
    '[--apply --released X --next Y] [--dry-run]',
  );
}

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  var check = false;
  var apply = false;
  var dryRun = false;
  String? released;
  String? next;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--check':
        check = true;
      case '--apply':
        apply = true;
      case '--dry-run':
        dryRun = true;
      case '--released':
        if (i + 1 >= args.length) _usage();
        released = args[++i];
      case '--next':
        if (i + 1 >= args.length) _usage();
        next = args[++i];
      case '-h':
      case '--help':
        _usage();
        exit(0);
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        _usage();
        exit(2);
    }
  }

  if (check == apply) {
    if (!check && !apply) check = true;
    if (check && apply) {
      stderr.writeln('Specify --check or --apply, not both');
      exit(2);
    }
  }

  if (check) {
    final checkScript = File('${root.path}/tool/release/check_package_changelogs.sh');
    final result = await Process.run('bash', [checkScript.path], runInShell: true);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exit(result.exitCode);
  }

  if (released == null || next == null) {
    stderr.writeln('--apply requires --released and --next');
    _usage();
    exit(2);
  }

  var changed = 0;
  for (final relPath in _followerChangelogPaths(root)) {
    final file = File('${root.path}/$relPath');
    if (!file.existsSync()) {
      throw StateError('Missing follower changelog: $relPath');
    }
    if (_applyFreeze(file: file, released: released, next: next, dryRun: dryRun)) {
      changed++;
      stdout.writeln('freeze_follower_changelogs: updated $relPath');
    }
  }
  stdout.writeln(
    'freeze_follower_changelogs: ${dryRun ? 'would update' : 'updated'} '
    '$changed follower changelog(s)',
  );
}
