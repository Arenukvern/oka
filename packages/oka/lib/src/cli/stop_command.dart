import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';

/// `oka stop <lease-id> [--force] [--stale] [--json]` — identity-verified,
/// graceful-first stop of one leased process (ADR-0018 §4); `--stale` runs
/// the L2 reconcile sweep (drops provably-stale records only).
///
/// The laws live in [stopLease] (oka_core): recycled pids are never
/// signaled, borrowed leases are refused without --force, an unverified
/// identity is reported rather than signaled, and the graceful stop_hint
/// runs before the force rung. `--json` emits the pipeline-events envelope
/// (scope "processes", event "stop.result").
class StopCommand {
  Future<void> run(final List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'force',
        negatable: false,
        help: 'Override the borrowed-lease refusal (explicit intent; the '
            'owning terminal may still be using the process)',
      )
      ..addFlag(
        'stale',
        negatable: false,
        help: 'Reconcile sweep: drop provably-stale records (process gone '
            'or pid recycled — never signaled). No live process is touched.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit one structured stop.result event instead of text',
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
      print('oka stop <lease-id> — stop a recorded process gracefully\n\n'
          '${parser.usage}');
      return;
    }
    if (results['stale'] as bool) {
      // ADR-0018 L2 reconcile sweep: drop provably-stale records only.
      // Live leases (orphans included) are reported, never auto-stopped.
      final sweep = await reconcileLeases(Directory.current.path);
      if (results['json'] as bool) {
        stdout.writeln(
          jsonEncode({
            'scope': 'processes',
            'event': 'stop.stale',
            'params': {
              'dropped': sweep.droppedStale,
              'orphans': sweep.orphans,
              'unverifiable': sweep.unverifiable,
            },
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          }),
        );
      } else {
        sweep.describeLines().forEach(print);
      }
      return;
    }
    final positional = results.rest.where((final a) => !a.startsWith('-'));
    if (positional.isEmpty) {
      stderr.writeln(
        'Usage: oka stop <lease-id> [--force] [--stale] [--json]\n'
        '   fix: `oka processes list` shows the recorded ids.',
      );
      exit(1);
    }
    final id = positional.first;

    final projectPath = Directory.current.path;
    final outcome = await stopLease(
      projectPath,
      id,
      force: results['force'] as bool,
    );

    if (results['json'] as bool) {
      stdout.writeln(
        jsonEncode({
          'scope': 'processes',
          'event': 'stop.result',
          'params': {
            'id': id,
            'ok': outcome.ok,
            'action': outcome.action.name,
            if (outcome.error != null) 'error': outcome.error,
          },
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } else {
      switch (outcome.action) {
        case LeaseStopAction.stopped:
          // ignore: avoid_print
          print('🛑 Process lease "$id" stopped.');
        case LeaseStopAction.recordDropped:
          // ignore: avoid_print
          print(
            '🧹 Process "$id" was already gone — stale record removed.',
          );
        case LeaseStopAction.failed:
        case LeaseStopAction.refused:
          stderr.writeln('❌ ${outcome.error}');
      }
    }
    if (!outcome.ok) exit(1);
  }
}
