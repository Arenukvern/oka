import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates the experimental live-update stack checkout for the delegating
/// CLI verbs (`oka live`, `oka ship`, `oka run dev`): the stack is
/// `publish_to: none`, so the published CLI carries no compile-time
/// dependency — when a checkout is present (`OKA_KERNEL_ROOT`, or the
/// source layout around this package …/oka/packages/oka → …/oka), verbs
/// run its tool with the workspace package config. Pub-global installs
/// live in .pub-cache — no checkout to find unless [OKA_KERNEL_ROOT] is set.
///
/// **Hosted `oka` on pub.dev:** `oka run dev` / `oka live` / `oka ship` need
/// either this monorepo checkout (auto-discovered from the `oka` script path)
/// or an explicit `OKA_KERNEL_ROOT` pointing at that checkout. CI must not
/// mask missing discovery by setting `OKA_KERNEL_ROOT` unless also exercising
/// the public auto-discovery path in a separate step.
///
/// [runner] is the tool path relative to the checkout, e.g.
/// `packages/oka_dart_kernel/tool/oka_live.dart`.
String? kernelStackRoot(String runner) =>
    kernelStackRootForScript(Platform.script.toFilePath(), runner);

/// Resolves the kernel checkout by walking upward from [scriptPath] until
/// [runner] exists. Handles nested layouts (e.g. GitHub `…/work/oka/oka/…`
/// where the first path segment named `oka` is not the repo root).
String? kernelStackRootForScript(
  String scriptPath,
  String runner, {
  Map<String, String>? environment,
}) {
  final env =
      (environment ?? Platform.environment)['OKA_KERNEL_ROOT']?.trim();
  if (env != null && env.isNotEmpty) {
    final root = p.normalize(env);
    if (File(p.join(root, runner)).existsSync() &&
        isOkaKernelWorkspaceRoot(root)) {
      return root;
    }
  }

  var dir = File(scriptPath).parent;
  while (true) {
    final candidate = dir.path;
    if (File(p.join(candidate, runner)).existsSync() &&
        isOkaKernelWorkspaceRoot(candidate)) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Runner-relative paths are insufficient — the tree must be an oka workspace.
bool isOkaKernelWorkspaceRoot(String root) {
  final normalized = p.normalize(root);
  final workspacePubspec = File(p.join(normalized, 'pubspec.yaml'));
  if (!workspacePubspec.existsSync()) return false;
  final workspaceText = workspacePubspec.readAsStringSync();
  if (!workspaceText.contains('name: oka_workspace') &&
      !workspaceText.contains('oka_workspace')) {
    return false;
  }
  return File(p.join(normalized, 'packages', 'oka', 'pubspec.yaml'))
          .existsSync() &&
      File(p.join(normalized, 'packages', 'oka_dart_kernel', 'pubspec.yaml'))
          .existsSync();
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
