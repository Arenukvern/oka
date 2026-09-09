// ADR-0015 C1 — the platform-leakage gate.
//
// ADR-0015's law: **verbs never know platforms.** The CLI layer (bin/ +
// lib/src/cli/) must contain no device/Android implementation logic — that
// logic lives in platform packages (oka_android's DeviceTarget, dex probe,
// SDK toolchain) behind the verb/target boundary.
//
// What this test asserts (deterministic string-list heuristics):
//
// 1. The files C1 folded (launch alias, debug-dex delegation, run
//    dispatcher, dev, plus bin/oka.dart, init, cache) contain none of the
//    forbidden implementation markers below.
// 2. No *new* leakage anywhere in the CLI layer: any file matching a
//    forbidden marker must be covered by the narrow, documented exceptions
//    below. The old per-file tracking allowlist (build / compare / doctor /
//    get) was emptied in the ADR-0015 follow-up: all four commands are now
//    parse-and-delegate shims over oka_android (compare.dart,
//    doctor_checks.dart, provisioning.dart, bundletool.dart) — additions
//    here fail by design (ratchet).
// 3. Per-command no-implementation assertions for the emptied commands.
//
// Forbidden markers (implementation signals, not doc words):
//  - adb, logcat, pidof, am start, platform-tools: device-layer
//    tool invocations (moved behind the device target / T2);
//  - aapt, apksigner, bundletool: Android SDK tool invocations;
//  - unzip, classesN.dex, badging: dex-probe/artifact-parsing
//    internals (the `debug dex` *verb name* is allowed — routing is static
//    per ADR-0015 — its implementation is not);
//  - package:oka_android/src/: the CLI may depend on platform packages
//    only through their public barrels, if at all.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _forbiddenMarkers = <String, RegExp>{
  'adb invocation': RegExp(r'\badb\b'),
  'logcat scanning': RegExp(r'\blogcat\b'),
  'pidof probing': RegExp(r'\bpidof\b'),
  'am start invocation': RegExp(r'\bam start\b'),
  'platform-tools path': RegExp('platform-tools'),
  'aapt invocation': RegExp(r'\baapt2?\b'),
  'apksigner invocation': RegExp(r'\bapksigner\b'),
  'bundletool invocation': RegExp(r'\bbundletool\b'),
  'unzip invocation': RegExp(r'\bunzip\b'),
  'dex file parsing': RegExp(r'classes\d*\.dex'),
  'badging parsing': RegExp(r'\bbadging\b'),
  'oka_android src import': RegExp('package:oka_android/src/'),
};

/// Narrow, documented exceptions to the zero-marker law. Each entry maps a
/// CLI file to the markers it may still match, and only for public CLI
/// *surface* (flag/routing text) — never implementation. The ratchet:
/// entries may be removed (fixed), never added.
///
/// Emptied in the ADR-0015 follow-up: the previous per-file tracking
/// allowlist (build / compare / doctor / get) is gone — see the per-command
/// assertions below.
const _documentedExceptions = <String, Map<String, String>>{
  'compare_command.dart': {
    'badging parsing':
        'the `--skip-badging` flag name is public CLI surface (documented in '
        'docs/guides/build_and_config.mdx); the badging-diff implementation '
        'itself lives in oka_android (compare.dart). The exception only '
        'covers the flag name — every matched line must contain it.',
  },
};

List<File> _cliFiles() => [
      File(p.join(Directory.current.path, 'packages', 'oka', 'bin', 'oka.dart')),
      ...Directory(p.join(
              Directory.current.path, 'packages', 'oka', 'lib', 'src', 'cli'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    ];

/// Returns marker hits per file, with line:col positions for the message.
Map<String, List<String>> _scan(final File file) {
  final hits = <String, List<String>>{};
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    for (final entry in _forbiddenMarkers.entries) {
      if (entry.value.hasMatch(lines[i])) {
        hits.putIfAbsent(entry.key, () => []).add('${i + 1}:${lines[i].trim()}');
      }
    }
  }
  return hits;
}

void main() {
  test('C1-folded files contain no platform implementation logic', () {
    // CLI paths are relative to packages/oka (the published CLI package).
    const mustBeClean = [
      'bin/oka.dart',
      'lib/src/cli/launch_command.dart',
      'lib/src/cli/debug_command.dart',
      'lib/src/cli/run_command.dart',
      'lib/src/cli/dev_command.dart',
      'lib/src/cli/init_command.dart',
      'lib/src/cli/cache_command.dart',
    ];
    for (final rel in mustBeClean) {
      final file = File(p.join(
          Directory.current.path, 'packages', 'oka', p.split(rel).join(p.separator)));
      expect(file.existsSync(), isTrue, reason: '$rel missing');
      final hits = _scan(file);
      expect(
        hits,
        isEmpty,
        reason: '$rel leaked platform logic (ADR-0015: verbs never know '
            'platforms):\n${hits.entries.map((e) => '  ${e.key}: '
                '${e.value.join('; ')}').join('\n')}',
      );
    }
  });

  test('no new platform leakage outside the documented exceptions', () {
    final unexpected = <String, String>{};
    for (final file in _cliFiles()) {
      final rel = p.relative(file.path, from: Directory.current.path);
      final name = p.basename(rel);
      final hits = _scan(file);
      if (hits.isEmpty) continue;
      final excepted = _documentedExceptions[name];
      if (excepted == null) {
        unexpected[rel] =
            hits.entries.map((e) => '${e.key}: ${e.value.first}').join('; ');
        continue;
      }
      // Every hit marker must be covered by the file's exception.
      for (final entry in hits.entries) {
        if (!excepted.containsKey(entry.key)) {
          unexpected[rel] = 'unexcepted ${entry.key}: ${entry.value.first}';
        }
      }
    }
    expect(
      unexpected,
      isEmpty,
      reason: 'New platform leakage in the CLI layer (ADR-0015: verbs never '
          'know platforms). Put the logic in a platform/target package and '
          'dispatch to it:\n${unexpected.entries.map((e) =>
              '  ${e.key}: ${e.value}').join('\n')}\n'
          'If a leak is genuinely pre-existing, add it to '
          '_documentedExceptions with its justification — additions there '
          'fail this test on purpose (it is a ratchet).',
    );
  });

  test('ADR-0015 follow-up: build/doctor/get CLI files are implementation-free', () {
    const emptied = [
      'lib/src/cli/build_command.dart',
      'lib/src/cli/doctor_command.dart',
      'lib/src/cli/get_command.dart',
    ];
    for (final rel in emptied) {
      final file = File(p.join(
          Directory.current.path, 'packages', 'oka', p.split(rel).join(p.separator)));
      expect(file.existsSync(), isTrue, reason: '$rel missing');
      final hits = _scan(file);
      expect(
        hits,
        isEmpty,
        reason: '$rel still leaks platform logic (ADR-0015 follow-up: the '
            'implementation moved to oka_android — the CLI file must be a '
            'parse-and-delegate shim):\n${hits.entries.map((e) => '  ${e.key}: '
                '${e.value.join('; ')}').join('\n')}',
      );
    }
  });

  test('compare_command: only the --skip-badging flag name may match', () {
    final file = File(
      p.join(Directory.current.path, 'packages', 'oka', 'lib', 'src', 'cli',
          'compare_command.dart'),
    );
    final hits = _scan(file);
    expect(
      hits.keys,
      ['badging parsing'],
      reason: 'only the `--skip-badging` flag name is excepted; everything '
          'else moved to oka_android (compare.dart)',
    );
    for (final line in hits['badging parsing'] ?? const <String>[]) {
      expect(
        line,
        contains('skip-badging'),
        reason: 'the badging exception covers only the flag name, not: $line',
      );
    }
  });
}
