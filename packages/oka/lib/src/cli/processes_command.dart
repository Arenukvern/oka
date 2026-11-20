import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';

/// `oka processes [list|reap] [--json]` — the lease inventory (ADR-0018
/// §4) and the foreign orphan reaping pass (ADR-0053).
///
/// `list`: every lease the project's registry records, each with its
/// reconcile verdict against the live host (live / stale-process-gone /
/// stale-pid-recycled / identity-unknown). Inspection only — nothing is
/// stopped or deleted here; `oka stop` and the L2 reconcile sweep mutate.
///
/// `reap` is the thin-shell form of `oka_core::reapForeignOrphans`
/// (ADR-0036 posture: the shell parses, the Dart API composes).
/// Persistent machine-local family/protected policy is a Dart
/// composition root — a driver calling `reapForeignOrphans` with its own
/// `targetNames`/`protectedNames` — never yaml config, never library
/// defaults; `--target`/`--allow` cover ad-hoc use.
class ProcessesCommand {
  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'json',
        negatable: false,
        help: 'Agent stream: one structured event per lease + a summary '
            '(the pipeline-events envelope, scope "processes")',
      )
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help')
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'reap: report candidates without signaling (ADR-0053 audit)',
      )
      ..addOption(
        'min-age-minutes',
        defaultsTo: '15',
        help: 'reap: age floor — younger matches are reported, not signaled',
      )
      ..addMultiOption(
        'allow',
        help: 'reap: extra protected command-line substrings (repeatable)',
      )
      ..addMultiOption(
        'target',
        help: 'reap: extra target command-line substrings (repeatable)',
      );

    late final ArgResults results;
    try {
      results = parser.parse(args);
    } on ArgParserException catch (e) {
      stderr.writeln('❌ ${e.message}\n   fix: ${parser.usage}');
      exit(1);
    }
    if (results['help'] as bool) {
      print('oka processes [list|reap] — lease inventory / foreign orphan '
          'reaping (ADR-0053)\n\n'
          '${parser.usage}');
      exit(0);
    }
    // `oka processes` and `oka processes list` are the same verb.
    final positional = results.rest.where((a) => !a.startsWith('-'));
    if (positional.isNotEmpty && positional.first == 'reap') {
      await _reap(results);
      return;
    }
    if (positional.isNotEmpty && positional.first != 'list') {
      stderr.writeln(
        '❌ Unknown subcommand "${positional.first}" — '
        'usage: oka processes [list|reap] [--json]',
      );
      exit(1);
    }

    final projectPath = Directory.current.path;
    final json = results['json'] as bool;
    final entries = await inventoryLeases(projectPath);

    if (json) {
      final now = DateTime.now().toUtc().toIso8601String();
      stdout.writeln(
        jsonEncode({
          'scope': 'processes',
          'event': 'processes.inventory',
          'params': {
            'count': entries.length,
            'leases': [for (final e in entries) e.toJson()],
          },
          'timestamp': now,
        }),
      );
      return;
    }

    if (entries.isEmpty) {
      print('No process leases recorded in this project.');
      return;
    }
    final stale = entries.where((e) => e.liveness.isStale).length;
    for (final e in entries) {
      // ignore: avoid_print
      print(e.toLine());
    }
    if (stale > 0) {
      // ignore: avoid_print
      print(
        '$stale stale record(s) — `oka stop <id>` drops them '
        '(never signals a recycled pid).',
      );
    }
  }

  /// `oka processes reap [--dry-run] [--min-age-minutes N] [--allow s]…
  /// [--target s]…` — the foreign orphan reaping pass (ADR-0053):
  /// SIGKILL the orphan-prone dart/flutter toolchain family whose parent
  /// died, identity-gated and receipted. Parse-and-delegate (ADR-0015);
  /// the laws live in `oka_core::reapForeignOrphans`, and machine-local
  /// policy composes there in Dart — not here.
  Future<void> _reap(ArgResults results) async {
    final projectPath = Directory.current.path;
    final dryRun = results['dry-run'] as bool;
    final minutes =
        int.tryParse(results['min-age-minutes'] as String? ?? '') ?? 15;
    final allows = results['allow'] as List<String>;
    final targets = results['target'] as List<String>;
    final summary = await reapForeignOrphans(
      projectPath,
      protectedNames: [...defaultForeignOrphanProtected, ...allows],
      targetNames: [...defaultForeignOrphanTargets, ...targets],
      minAge: Duration(minutes: minutes),
      dryRun: dryRun,
    );
    if (results['json'] as bool) {
      stdout.writeln(
        jsonEncode({
          'scope': 'processes',
          'event': 'processes.reap',
          'params': {
            'dry_run': dryRun,
            'receipts': [for (final r in summary.receipts) r.toJson()],
          },
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      return;
    }
    // ignore: avoid_print
    summary.describeLines().forEach(print);
  }
}
