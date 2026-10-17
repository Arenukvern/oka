/// Finite, explicit convergence; the leased worker outlives this runner.
library;

import 'dart:convert';
import 'dart:io';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';

Future<void> main(List<String> args) async {
  try {
    final options = <String, String>{};
    var stop = false;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--stop') {
        stop = true;
      } else if (args[i] == '--help') {
        stdout.writeln(
          'codemap_index.dart --root ROOT --executable CODEMAP '
          '[--receipt PATH] [--scope-json JSON] [--passes N] '
          '[--interval-ms N] [--stop]',
        );
        return;
      } else if ([
            '--root',
            '--executable',
            '--receipt',
            '--scope-json',
            '--passes',
            '--interval-ms',
          ].contains(args[i]) &&
          i + 1 < args.length) {
        final key = args[i];
        options[key] = args[++i];
      } else {
        throw ArgumentError('unknown or missing argument: ${args[i]}');
      }
    }
    if (options['--root'] == null || options['--executable'] == null) {
      throw ArgumentError('--root and --executable required');
    }
    final passes = int.parse(options['--passes'] ?? '1');
    final interval = int.parse(options['--interval-ms'] ?? '1000');
    if (passes < 1 || passes > 10000 || interval < 1 || interval > 60000) {
      throw ArgumentError('passes 1..10000; interval-ms 1..60000');
    }
    final recipe = CodemapIndexRecipe(
      executable: options['--executable']!,
      projectRoot: options['--root']!,
      receiptPath: options['--receipt'],
      scope: options['--scope-json'] == null
          ? null
          : Map<String, Object?>.from(
              jsonDecode(options['--scope-json']!) as Map,
            ),
    );
    var provider = recipe.provider();
    final supervisor = Supervisor(projectRoot: recipe.projectRoot);
    ResourceRef? ref() {
      final r = supervisor.registry.read(supervisor.scope, recipe.id);
      return r?.pid == null
          ? null
          : ResourceRef(
              componentId: r!.componentId,
              handle: r.handle!,
              pid: r.pid,
              identityToken: r.identityToken,
            );
    }

    if (stop) {
      final record = supervisor.registry.read(supervisor.scope, recipe.id);
      if (record?.killPolicy == KillPolicy.none) {
        throw StateError('unowned worker; teardown refused');
      }
      final worker = ref();
      if (worker == null) throw StateError('no worker');
      final result = await provider.stop(
        worker,
        grace: const Duration(seconds: 3),
      );
      stdout.writeln(
        jsonEncode({
          'stop': result.disposition.name,
          'message': result.message,
        }),
      );
      if (!result.stopped) exitCode = 1;
      exit(exitCode);
    }
    for (var pass = 0; pass < passes; pass++) {
      provider = recipe.provider();
      final report = await supervisor.converge(
        desired: recipe.desired,
        factory: (_) => provider,
      );
      final worker = ref();
      final health = worker == null ? null : provider.health(worker);
      stdout.writeln(
        jsonEncode({
          'pass': pass + 1,
          'started': report.started,
          'restarted': report.restarted,
          'failed_starts': report.failedStarts,
          'findings': [
            for (final f in report.plan.findings)
              {'code': f.code, 'message': f.message},
          ],
          'index_health': health?.state,
          'index_message': health?.message,
        }),
      );
      if (!report.ok ||
          report.plan.findings.any((f) => f.code == 'giveUp')) {
        exitCode = 1;
      }
      if (pass + 1 < passes) {
        await Future<void>.delayed(Duration(milliseconds: interval));
      }
    }
  } on Object catch (error) {
    stderr.writeln('codemap_index: $error');
    exitCode = 2;
  }
  // Close runtime process ports after the explicitly finite pass window.
  // The leased worker is retained for future convergence or owned teardown.
  exit(exitCode);
}
