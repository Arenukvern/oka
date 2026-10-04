import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates the experimental live-update stack checkout for the delegating
/// CLI verbs (`oka live`, `oka ship`, `oka run dev`): the stack is
/// `publish_to: none`, so the published CLI carries no compile-time
/// dependency — when a checkout is present (`OKA_KERNEL_ROOT`, or the
/// source layout around this package …/oka/packages/oka → …/oka), verbs
/// run its tool with the workspace package config. Pub-global installs
/// live in .pub-cache — no checkout to find.
///
/// [runner] is the tool path relative to the checkout, e.g.
/// `packages/oka_dart_kernel/tool/oka_live.dart`.
String? kernelStackRoot(String runner) {
  final env = Platform.environment['OKA_KERNEL_ROOT'];
  if (env != null && File(p.join(env, runner)).existsSync()) return env;
  final segments = p.split(Platform.script.toFilePath());
  final okaIndex = segments.indexOf('oka');
  if (okaIndex > 0) {
    final candidate = p.joinAll(segments.sublist(0, okaIndex + 1));
    if (File(p.join(candidate, runner)).existsSync()) return candidate;
  }
  return null;
}

/// Spawns [tool] from the kernel-stack checkout with the workspace package
/// config and the caller's stdio, and exits with its code. When the stack
/// is not available, prints [missingMessage] and exits 2.
Future<void> delegateToKernelStack({
  required String runner,
  required List<String> args,
  required String missingMessage,
}) async {
  final root = kernelStackRoot(runner);
  if (root == null) {
    stderr.writeln(missingMessage);
    exitCode = 2;
    return;
  }
  final packagesConfig = '$root/.dart_tool/package_config.json';
  if (!File(packagesConfig).existsSync()) {
    stderr.writeln(
        'run `dart pub get --no-example` in $root (missing '
        'package_config.json)');
    exitCode = 2;
    return;
  }
  final proc = await Process.start(
    'dart',
    [
      '--packages=$packagesConfig',
      p.join(root, runner),
      ...args,
    ],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await proc.exitCode;
}
