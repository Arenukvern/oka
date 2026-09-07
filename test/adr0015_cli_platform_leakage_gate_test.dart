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
//    forbidden marker must be in the explicit, documented allowlist below
//    (tracked items that still route through oka_android until ADR-0013/T1
//    moves tool resolution behind tool providers). Shrinking the allowlist
//    always passes; growing it — or adding a new file to it — fails.
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

/// Files that still contain platform markers, each with the tracking item
/// that will remove them. A ratchet: entries may be removed (fixed), never
/// added.
const _allowlistedLeaks = <String, String>{
  'build_command.dart':
      'verify-aab bundletool wiring + install hint (ADR-0013/T1: '
      'resolve through tool providers)',
  'compare_command.dart':
      'aapt2 badging diff implementation (ADR-0013/T1 routing; '
      'byte-equivalence must be preserved across the move)',
  'doctor_command.dart':
      'tool presence checks (ADR-0013/T1: print resolved policy)',
  'get_command.dart':
      'android-sdk provisioning (ADR-0013/T1: route through tool providers)',
};

List<File> _cliFiles() => [
      File(p.join(Directory.current.path, 'bin', 'oka.dart')),
      ...Directory(p.join(Directory.current.path, 'lib', 'src', 'cli'))
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
      final file = File(p.join(Directory.current.path, rel));
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

  test('no new platform leakage outside the documented allowlist', () {
    final unexpected = <String, String>{};
    for (final file in _cliFiles()) {
      final rel = p.relative(file.path, from: Directory.current.path);
      final name = p.basename(rel);
      final hits = _scan(file);
      if (hits.isEmpty) continue;
      if (!_allowlistedLeaks.containsKey(name)) {
        unexpected[rel] =
            hits.entries.map((e) => '${e.key}: ${e.value.first}').join('; ');
      }
    }
    expect(
      unexpected,
      isEmpty,
      reason: 'New platform leakage in the CLI layer (ADR-0015: verbs never '
          'know platforms). Put the logic in a platform/target package and '
          'dispatch to it:\n${unexpected.entries.map((e) =>
              '  ${e.key}: ${e.value}').join('\n')}\n'
          'If a leak is genuinely pre-existing, add it to _allowlistedLeaks '
          'with its tracking item — additions there fail this test on '
          'purpose (it is a ratchet).',
    );
  });
}
