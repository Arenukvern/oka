import 'dart:io';

import 'package:path/path.dart' as p;

import 'budget.dart';
import 'cache_key.dart';
import 'frontend_server_session.dart';
import 'import_graph.dart';

String testWorkspaceRoot(String workingDirectory) {
  var directory = Directory(workingDirectory).absolute;
  while (!File('${directory.path}/.dart_tool/package_config.json')
      .existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('No package_config.json above $workingDirectory');
    }
    directory = parent;
  }
  return directory.path;
}

/// Cache the unmodified package:test executable, rather than booting dartdev
/// (and every unrelated workspace native build hook) on each pure-Dart run.
/// Native-asset suites retain the ordinary SDK test path.
Future<String> testRunnerKernel(String root, VerifyBudget budget) async {
  final graph = await WorkspaceGraph.load(root);
  final testRoot = graph.packageRoot('test');
  if (testRoot == null) throw StateError('package:test is not resolved');
  final entry = p.join(testRoot, 'bin', 'test.dart');
  final closure = graph.closureOf(entry);
  final key = computeSuiteKey(
    closure: closure,
    fileHashes: {for (final file in closure) file: hashFile(file)},
    context: CacheKeyContext.current(
      packageConfigJson: File('$root/.dart_tool/package_config.json')
          .readAsStringSync(),
      sdkVersion: Platform.version,
      contractVersion: 'package-test-executable-v1',
    ),
  );
  final cache = Directory('$root/.dart_tool/oka_verify/runner')
    ..createSync(recursive: true);
  final destination = '${cache.path}/$key.dill';
  if (File(destination).existsSync()) return destination;
  final token = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  final staging = '$destination.$token.tmp';
  final sdk = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
  final session = await FrontendServerSession.start(
    sdkRoot: p.dirname(p.dirname(sdk)),
    scratchDill: '${cache.path}/scratch-$token.dill',
    packagesPath: '$root/.dart_tool/package_config.json',
  );
  try {
    final result = await session
        .compile(entry, copyTo: staging)
        .timeout(budget.compileTimeout);
    if (!result.ok) {
      throw StateError('test runner compilation failed: ${result.diagnostics}');
    }
    await File(staging).rename(destination);
    return destination;
  } finally {
    await session.quit();
    if (File(staging).existsSync()) await File(staging).delete();
  }
}
