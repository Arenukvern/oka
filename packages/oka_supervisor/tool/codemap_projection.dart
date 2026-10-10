/// Read-only projection CLI for codemap's declared command lanes
/// (ADR-0041 law 7: a foreign runner's declarations are read, never
/// executed — this tool parses JSON and stats files, nothing more).
///
/// Usage:
///
/// ```
/// dart run tool/codemap_projection.dart --snapshot <lanes.json> \
///     [--receipts <dir-or-file>] [--root <project>] [--json] [--check]
/// ```
///
/// - `--snapshot` (required): codemap lane declarations as data —
///   `<root>/scripts/lanes.json`, or the runner's read-only audit
///   capture `tools/ops/run_lanes.py --list > lanes.json`. Never the
///   typed Python form; this tool does not import or execute it.
/// - `--receipts`: a capture directory (one file per receipt/log) or a
///   single capture file (pretty JSON or JSONL). Omit it to project
///   declarations only (every lane reports unrun/unknown).
/// - `--root`: base for relative `--snapshot` / `--receipts` paths
///   (default: current directory).
/// - `--json`: machine document instead of aligned text.
/// - `--check`: the future CI hook (ADR-0041 rung 2) — exits 1 when
///   any overdue / unrun / corruptReceipt finding exists.
///
/// Exit codes: 0 read projected; 1 `--check` found attention-worthy
/// findings; 2 usage or unreadable/invalid input.
library;

import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:path/path.dart' as p;

Future<void> main(final List<String> arguments) async {
  String? snapshotPath;
  String? receiptsPath;
  var root = Directory.current.path;
  var asJson = false;
  var check = false;

  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    switch (argument) {
      case '--snapshot':
      case '--receipts':
        final value = _value(arguments, ++i, argument);
        if (argument == '--snapshot') {
          snapshotPath = value;
        } else {
          receiptsPath = value;
        }
      case '--root':
        root = _value(arguments, ++i, argument);
      case '--json':
        asJson = true;
      case '--check':
        check = true;
      case '-h':
      case '--help':
        stdout.writeln(_usage);
        return;
      default:
        stderr
          ..writeln('codemap_projection: unknown argument $argument')
          ..writeln(_usage);
        exit(2);
    }
  }

  if (snapshotPath == null) {
    stderr
      ..writeln('codemap_projection: --snapshot <lanes.json> is required')
      ..writeln(_usage);
    exit(2);
  }

  try {
    final snapshot = CodemapLaneSnapshot.parse(
      File(_resolve(root, snapshotPath)).readAsStringSync(),
    );
    final projection = projectCodemapLanes(
      snapshot: snapshot,
      receiptsPath: receiptsPath == null ? null : _resolve(root, receiptsPath),
    );
    stdout.writeln(
      asJson ? projectionJson(projection) : renderProjection(projection),
    );
    exit(check && projection.needsAttention ? 1 : 0);
  } on FormatException catch (error) {
    stderr.writeln('codemap_projection: ${error.message}');
    exit(2);
  } on FileSystemException catch (error) {
    stderr.writeln('codemap_projection: ${error.message}');
    exit(2);
  }
}

String _value(
  final List<String> arguments,
  final int index,
  final String flag,
) {
  if (index >= arguments.length) {
    stderr.writeln('codemap_projection: $flag needs a value');
    exit(2);
  }
  return arguments[index];
}

String _resolve(final String root, final String target) =>
    p.isAbsolute(target) ? target : p.normalize(p.join(root, target));

const _usage =
    'usage: dart run tool/codemap_projection.dart --snapshot <lanes.json> '
    '[--receipts <dir-or-file>] [--root <project>] [--json] [--check]';
