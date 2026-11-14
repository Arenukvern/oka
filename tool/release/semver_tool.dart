#!/usr/bin/env dart

import 'dart:io';

List<int> _parts(String version) {
  final match = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
      .firstMatch(version.trim());
  if (match == null) {
    stderr.writeln('semver_tool: invalid semver: $version');
    exit(2);
  }
  return [int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!)];
}

int compareSemver(String left, String right) {
  final a = _parts(left);
  final b = _parts(right);
  for (var i = 0; i < 3; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

String bumpMinor(String version) {
  final p = _parts(version);
  return '${p[0]}.${p[1] + 1}.0';
}

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('usage: semver_tool.dart {cmp|bump-minor} ...');
    exit(2);
  }
  switch (arguments.first) {
    case 'cmp':
      if (arguments.length != 3) {
        stderr.writeln('usage: semver_tool.dart cmp A B');
        exit(2);
      }
      stdout.write(compareSemver(arguments[1], arguments[2]));
    case 'bump-minor':
      if (arguments.length != 2) {
        stderr.writeln('usage: semver_tool.dart bump-minor VERSION');
        exit(2);
      }
      stdout.write(bumpMinor(arguments[1]));
    default:
      stderr.writeln('semver_tool: unknown command: ${arguments.first}');
      exit(2);
  }
}
