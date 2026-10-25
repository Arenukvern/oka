/// The `oka_verify` CLI (ADR-0048): pay Dart's compile cost once, then
/// iterate.
///
///   dart run oka_verify --package my_package
///   dart run oka_verify --package my_package --only widget
///   dart run oka_verify --package my_package --all
///   dart run oka_verify --package my_package --no-run
///
/// The exit code mirrors `dart test`. The last stderr line is always
/// `oka-receipt: <path>` — a JSON receipt naming the git revision, the
/// SDK, the changed files, the selected/rebuilt/cache-hit counts, the
/// phase timings and the widget suites the lane refused.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../oka_verify.dart';

/// Exit code for a usage error.
const int usageExitCode = 64;

/// Exit code for a kernel rebuild failure.
const int rebuildFailureExitCode = 65;

/// Exit code for "nothing to verify".
const int nothingToVerifyExitCode = 66;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('package', help: 'The workspace package to verify (required).')
    ..addOption(
      'root',
      help: 'Workspace root (defaults to the nearest package_config.json).',
    )
    ..addFlag(
      'all',
      negatable: false,
      help: 'Verify every suite of the package.',
    )
    ..addMultiOption(
      'only',
      help: 'Verify only the suites whose path contains this substring.',
    )
    ..addOption(
      'changed',
      help: 'Comma-separated changed files (overrides the git query).',
    )
    ..addFlag(
      'no-run',
      negatable: false,
      help: 'Build/validate the kernels without running the suites.',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: 'Print the receipt as JSON on stdout.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on ArgParserException catch (error) {
    stderr
      ..writeln('invalid arguments: ${error.message}')
      ..writeln(parser.usage);
    exit(usageExitCode);
  }
  if (results['help'] as bool) {
    stdout
      ..writeln(_usage)
      ..writeln(parser.usage);
    return;
  }
  final packageName = results['package'] as String?;
  if (packageName == null || packageName.isEmpty) {
    stderr
      ..writeln('--package is required')
      ..writeln(parser.usage);
    exit(usageExitCode);
  }

  final root = _resolveRoot(results['root'] as String?);
  if (root == null) {
    stderr.writeln(
      'no workspace root found: no .dart_tool/package_config.json above '
      '${Directory.current.path}',
    );
    exit(usageExitCode);
  }

  final options = VerifyOptions(
    repoRoot: root,
    packageName: packageName,
    all: results['all'] as bool,
    only: results['only'] as List<String>,
    changed: _changedOverride(results['changed'] as String?),
    noRun: results['no-run'] as bool,
  );

  final lane = OkaVerify(
    budget: VerifyBudget.standard(),
    log: (message) => stderr.writeln(message),
  );
  final VerifyResult result;
  try {
    result = await lane.run(options);
  } on Object catch (error) {
    stderr.writeln('[oka-verify] failed: $error');
    exit(1);
  }

  if (result.error != null) {
    stderr.writeln('[oka-verify] ${result.error}');
    exit(result.exitCode);
  }
  if (results['json'] as bool) {
    stdout.writeln(result.receipt.encode());
  }
  final receipt = result.receipt;
  stderr.writeln(
    '[oka-verify] ${receipt.selectedSuites.length} suites · '
    '${receipt.rebuiltSuites.length} rebuilt · '
    '${receipt.cacheHits} cache hits · '
    'rebuild ${receipt.rebuildMs} ms · run ${receipt.runMs} ms',
  );
  if (receipt.broadenReason != null) {
    stderr.writeln('[oka-verify] widened: ${receipt.broadenReason}');
  }
  if (receipt.refusedFlutterSuites.isNotEmpty) {
    stderr.writeln(
      '[oka-verify] refused ${receipt.refusedFlutterSuites.length} widget '
      'suite(s) — they need `flutter test`',
    );
  }
  stderr.writeln('oka-receipt: ${result.receiptPath}');
  exit(result.exitCode);
}

/// The workspace root: the explicit `--root`, else the nearest ancestor
/// with a `package_config.json`.
String? _resolveRoot(String? explicit) {
  if (explicit != null && explicit.isNotEmpty) {
    return Directory(explicit).absolute.path;
  }
  var current = Directory.current.absolute.path;
  while (true) {
    final config = p.join(current, '.dart_tool', 'package_config.json');
    if (File(config).existsSync()) return current;
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

List<String>? _changedOverride(String? raw) {
  if (raw == null) return null;
  final files = [
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  return files;
}

const String _usage = '''
usage: oka_verify --package <name> [--root <repoRoot>]
                  [--all | --only <substr>]... [--changed <f1,f2>]
                  [--no-run] [--json]

  Rebuilds stale suite kernels (closure-hash keyed) and runs the selected
  suites through `dart test --precompiled`. Selection defaults to the
  suites a change reaches; --all widens it, --only narrows it by
  substring, and unknown dependency coverage widens it to every suite.

  Widget suites are refused (they need `flutter test`); plain `dart test`
  stays the acceptance oracle.
''';
