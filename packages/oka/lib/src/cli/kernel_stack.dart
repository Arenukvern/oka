import 'dart:io';

import 'package:oka_dart_kernel/dev_session.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Locates the experimental live-update stack checkout for the verbs that
/// are still checkout-only (`oka live`, `oka ship`). The stack runner is a
/// tool script: when a checkout is present (`OKA_KERNEL_ROOT`, or the source
/// layout around this package), those verbs run it with the workspace
/// package config.
///
/// `oka dev` does not use this walk. It calls the published dev session.
/// `OKA_KERNEL_ROOT` remains an explicit override for that one command when
/// someone is working on the session itself.
///
const devSessionRunner = 'packages/oka_dart_kernel/tool/oka_run_dev.dart';

/// Runs the dev session built into this executable.
///
/// `OKA_KERNEL_ROOT`, when it points at a checkout that contains
/// [devSessionRunner], runs that script instead. A set but unusable value
/// fails. An unset value never searches the filesystem.
Future<void> runPublishedDevSession(List<String> args) async {
  final pinned = Platform.environment['OKA_KERNEL_ROOT']?.trim();
  if (pinned == null || pinned.isEmpty) {
    await runRunDevCli(args);
    return;
  }
  final root = explicitKernelStackRoot(devSessionRunner);
  if (root == null) {
    stderr.writeln(
      'OKA_KERNEL_ROOT does not contain $devSessionRunner.\n'
      'Unset it to use the dev session built into this oka.',
    );
    exitCode = 2;
    return;
  }
  await spawnKernelRunner(root: root, runner: devSessionRunner, args: args);
}

/// [runner] is the tool path relative to the checkout, e.g.
/// `packages/oka_dart_kernel/tool/oka_live.dart`.
String? kernelStackRoot(String runner) =>
    kernelStackRootForScript(Platform.script.toFilePath(), runner);

/// The `OKA_KERNEL_ROOT` checkout when it contains [runner]. A bad value
/// does not fall through to the script-path walk.
String? explicitKernelStackRoot(
  String runner, {
  Map<String, String>? environment,
}) {
  final env = (environment ?? Platform.environment)['OKA_KERNEL_ROOT']?.trim();
  if (env == null || env.isEmpty) return null;
  final root = p.normalize(env);
  if (File(p.join(root, runner)).existsSync() &&
      isOkaKernelWorkspaceRoot(root)) {
    return root;
  }
  return null;
}

/// Resolves the kernel checkout by walking upward from [scriptPath] until
/// [runner] exists. Handles nested layouts (e.g. GitHub `…/work/oka/oka/…`
/// where the first path segment named `oka` is not the repo root).
String? kernelStackRootForScript(
  String scriptPath,
  String runner, {
  Map<String, String>? environment,
}) {
  final env = (environment ?? Platform.environment)['OKA_KERNEL_ROOT']?.trim();
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
  try {
    final doc = loadYaml(workspacePubspec.readAsStringSync());
    if (doc is! YamlMap) return false;
    if (doc['name']?.toString() != 'oka_workspace') return false;
  } on Object {
    return false;
  }
  return _packagePubspecNamed(normalized, 'oka', 'oka') &&
      _packagePubspecNamed(normalized, 'oka_dart_kernel', 'oka_dart_kernel');
}

bool _packagePubspecNamed(String workspaceRoot, String folder, String name) {
  final pubspec = File(
    p.join(workspaceRoot, 'packages', folder, 'pubspec.yaml'),
  );
  if (!pubspec.existsSync()) return false;
  try {
    final doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) return false;
    return doc['name']?.toString() == name;
  } on Object {
    return false;
  }
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
  await spawnKernelRunner(root: root, runner: runner, args: args);
}

/// Runs [runner] under [root] with that workspace's package config.
Future<void> spawnKernelRunner({
  required String root,
  required String runner,
  required List<String> args,
}) async {
  final packagesConfig = '$root/.dart_tool/package_config.json';
  if (!File(packagesConfig).existsSync()) {
    stderr.writeln(
      'run `dart pub get --no-example` in $root (missing '
      'package_config.json)',
    );
    exitCode = 2;
    return;
  }
  final proc = await Process.start('dart', [
    '--packages=$packagesConfig',
    p.join(root, runner),
    ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await proc.exitCode;
}
