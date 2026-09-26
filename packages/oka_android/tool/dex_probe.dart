import 'dart:io';

import 'package:oka_android/src/compilation/bytecode_compilation.dart';

/// Probes the runtime-jar filter with paths supplied by the caller.
///
/// Run from `packages/oka_android`:
/// `dart run tool/dex_probe.dart <jar-path> [<jar-path> ...]`
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/dex_probe.dart <jar-path> [<jar-path> ...]',
    );
    exitCode = 64;
    return;
  }

  final missing = args.where((final jar) => !File(jar).existsSync()).toList();
  if (missing.isNotEmpty) {
    for (final jar in missing) {
      stderr.writeln('Jar does not exist: $jar');
    }
    exitCode = 66;
    return;
  }

  final out = filterRuntimeJars(args);
  print('kept ${out.length} of ${args.length}:');
  for (final j in out) {
    print('  $j');
  }
}
