import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';

/// `oka processes list [--json]` — the lease inventory (ADR-0018 §4).
///
/// Every lease the project's registry records, each with its reconcile
/// verdict against the live host (live / stale-process-gone / stale-pid-
/// recycled / identity-unknown). Inspection only — nothing is stopped or
/// deleted here; `oka stop` and the L2 reconcile sweep mutate.
class ProcessesCommand {
  Future<void> run(final List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'json',
        negatable: false,
        help: 'Agent stream: one structured event per lease + a summary '
            '(the pipeline-events envelope, scope "processes")',
      )
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    late final ArgResults results;
    try {
      results = parser.parse(args);
    } on ArgParserException catch (e) {
      stderr.writeln('❌ ${e.message}\n   fix: ${parser.usage}');
      exit(1);
    }
    if (results['help'] as bool) {
      print('oka processes list — show recorded process leases\n\n'
          '${parser.usage}');
      exit(0);
    }
    // `oka processes` and `oka processes list` are the same verb.
    final positional = results.rest.where((final a) => !a.startsWith('-'));
    if (positional.isNotEmpty && positional.first != 'list') {
      stderr.writeln(
        '❌ Unknown subcommand "${positional.first}" — '
        'usage: oka processes [list] [--json]',
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
    final stale = entries.where((final e) => e.liveness.isStale).length;
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
}
