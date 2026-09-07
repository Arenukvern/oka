/// Static DEX symbol check (ADR-0015: moved behind the Android package —
/// this used to live in the CLI's `oka debug dex` implementation).
///
/// Verifies a class descriptor appears in the APK's `classes*.dex` string
/// pools. Catches runtime dependency gaps (NoClassDefFoundError at startup)
/// BEFORE installing — the class must be either defined or referenced in a
/// dex, or the app is guaranteed to crash. Presence is "defined or
/// referenced" (string-pool heuristic); absence is a hard failure.
///
/// DEX descriptors are stored as plain UTF-8/MUTF-8 — a byte search is
/// exact for class descriptors, so the pools are scanned as raw strings.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Outcome of [checkDexSymbols].
class DexProbeOutcome {
  const DexProbeOutcome({
    required this.dexEntriesFound,
    required this.allPresent,
  });

  /// False when the APK contains no `classes*.dex` entries (or is not a
  /// readable zip) — a hard error, distinct from a missing symbol.
  final bool dexEntriesFound;

  /// False when at least one queried class descriptor is absent.
  final bool allPresent;

  /// True when the APK has dex pools and every queried symbol is present.
  bool get ok => dexEntriesFound && allPresent;

  /// Exit-code semantics: ok → 0, missing symbol → 1, no dex → 2.
  int get exitCode => !dexEntriesFound ? 2 : allPresent ? 0 : 1;
}

/// Runs the DEX symbol probe and prints the per-class report (same output
/// the `oka debug dex` verb has always shown — the verb only parses args).
///
/// [emit] overrides printing (tests); [queries] are dotted
/// (`kotlinx.atomicfu.AtomicFU`) or descriptor (`Lkotlinx/atomicfu/...;`)
/// class names.
Future<DexProbeOutcome> checkDexSymbols({
  required final String apk,
  required final List<String> queries,
  final void Function(String message)? emit,
}) async {
  final out = emit ?? print;

  final pools = <String, String>{};
  try {
    final bytes = await File(apk).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (!file.isFile) continue;
      if (!RegExp(r'classes\d*\.dex$').hasMatch(file.name)) continue;
      pools[file.name] = String.fromCharCodes(file.content as List<int>);
    }
  } on Exception catch (e) {
    out('❌ no classes*.dex in $apk: $e');
    return const DexProbeOutcome(
      dexEntriesFound: false,
      allPresent: false,
    );
  }
  if (pools.isEmpty) {
    out('❌ no classes*.dex in $apk');
    return const DexProbeOutcome(
      dexEntriesFound: false,
      allPresent: false,
    );
  }

  var failed = false;
  out('🔍 DEX symbol check: ${p.basename(apk)}');
  for (final q in queries) {
    final descriptor = q.startsWith('L') ? q : 'L${q.replaceAll('.', '/')};';
    final hits = pools.entries
        .where((final e) => e.value.contains(descriptor))
        .map((final e) => e.key)
        .toList();
    if (hits.isEmpty) {
      failed = true;
      out('  ❌ $descriptor — ABSENT from all dex files');
      out(
        '     Referencing code will throw NoClassDefFoundError at '
        'runtime (kills GeneratedPluginRegistrant).',
      );
    } else {
      out('  ✅ $descriptor — in ${hits.join(', ')}');
    }
  }
  return DexProbeOutcome(dexEntriesFound: true, allPresent: !failed);
}
