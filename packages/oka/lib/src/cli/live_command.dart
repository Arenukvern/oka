import 'dart:io';

import 'package:path/path.dart' as p;

/// `oka live` — delegates to the experimental live-update runner
/// (`oka_dart_kernel/tool/oka_live.dart`, ADR-0036 Tier 2).
///
/// The live stack is `publish_to: none`, so the published CLI carries no
/// compile-time dependency: when a checkout is present (sibling package
/// or `OKA_KERNEL_ROOT`), this runs its tool with the workspace package
/// config and passes through output and exit code. Without it, the error
/// says where the stack lives.
class LiveCommand {
  Future<void> run(List<String> args) async {
    final root = _kernelRoot();
    if (root == null) {
      stderr.writeln(
          'oka live: the experimental live-update stack is not available.\n'
          'Point OKA_KERNEL_ROOT at a checkout with '
          'packages/oka_dart_kernel (see docs/guides/live_update.mdx).');
      exitCode = 2;
      return;
    }
    final packagesConfig = '$root/.dart_tool/package_config.json';
    if (!File(packagesConfig).existsSync()) {
      stderr.writeln('oka live: run `dart pub get --no-example` in $root '
          '(missing package_config.json)');
      exitCode = 2;
      return;
    }
    final proc = await Process.start(
      'dart',
      [
        '--packages=$packagesConfig',
        p.join(root, 'packages/oka_dart_kernel/tool/oka_live.dart'),
        ...args,
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await proc.exitCode;
  }

  /// A checkout whose `packages/oka_dart_kernel/tool/oka_live.dart`
  /// exists: `OKA_KERNEL_ROOT`, else the source layout around this
  /// package (…/oka/packages/oka → …/oka).
  String? _kernelRoot() {
    final env = Platform.environment['OKA_KERNEL_ROOT'];
    if (env != null && File(p.join(env, _runner)).existsSync()) return env;
    // Pub-global installs live in .pub-cache — no checkout to find.
    final segments = p.split(Platform.script.toFilePath());
    final okaIndex = segments.indexOf('oka');
    if (okaIndex > 0) {
      final candidate = p.joinAll(segments.sublist(0, okaIndex + 1));
      if (File(p.join(candidate, _runner)).existsSync()) return candidate;
    }
    return null;
  }

  static const _runner =
      'packages/oka_dart_kernel/tool/oka_live.dart';
}
