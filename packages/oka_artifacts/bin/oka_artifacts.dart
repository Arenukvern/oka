import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:path/path.dart' as p;

/// `dart run bin/oka_artifacts.dart` — the store's CLI seam (ADR-0043):
/// put (record + optional pointer), materialize, verify, status.
Future<void> main(final List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln(_usage);
    return;
  }
  final parser = ArgParser()
    ..addOption('root', help: 'Store root (defaults to ~/.oka/artifacts).')
    ..addOption('name', help: 'Artifact key (e.g. harnessd-jit-dill).')
    ..addOption(
      'codec',
      help: 'Delta codec: zstd (default) or none (snapshots only).',
    )
    ..addOption('rollover', help: 'DeltaChain rollover ratio (0..1).')
    ..addOption('sdk', help: 'Provenance: SDK version (put).')
    ..addOption('inputs', help: 'Provenance: input-set hash (put).')
    ..addOption('entrypoint', help: 'Provenance: entrypoint (put).')
    ..addOption(
      'backend',
      help: 'Provenance: backend URI for the pointer (put).',
    )
    ..addOption(
      'pointer',
      help: 'Write an ArtifactPointer manifest here (put).',
    )
    ..addOption('out', abbr: 'o', help: 'Materialize target file.')
    ..addFlag('json', negatable: false, help: 'Emit JSON.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on ArgParserException catch (error) {
    stderr
      ..writeln('invalid arguments: ${error.message}')
      ..writeln(parser.usage);
    exitCode = 2;
    return;
  }
  if (results['help'] as bool) {
    stdout
      ..writeln(_usage)
      ..writeln(parser.usage);
    return;
  }

  final store = ArtifactStore(
    root: Directory(
      (results['root'] as String?) ??
          p.join(Platform.environment['HOME'] ?? '.', '.oka', 'artifacts'),
    ),
  );
  final codec = (results['codec'] as String?) == 'none'
      ? null
      : const ZstdCliCodec();

  switch (args.first) {
    case 'put':
      _put(store, codec, results, args);
    case 'materialize':
      _materialize(store, codec, results, args);
    case 'verify':
      _verify(store, codec, results, args);
    case 'status':
      _status(store, results, args);
    default:
      stderr.writeln(
        'unknown command "${args.first}"; '
        'use put, materialize, verify or status',
      );
      exitCode = 2;
  }
}

void _put(
  final ArtifactStore store,
  final DeltaCodec? codec,
  final ArgResults results,
  final List<String> args,
) {
  final name = results['name'] as String?;
  final path = args.length > 1 ? args[1] : null;
  if (name == null || path == null) {
    stderr.writeln('usage: put <file> --name <name>');
    exitCode = 2;
    return;
  }
  final bytes = File(path).readAsBytesSync();
  final rollover = results['rollover'] as String?;
  final StorageStrategy strategy;
  if (rollover == null) {
    strategy = codec == null ? const SnapshotOnly() : const DeltaChain();
  } else {
    strategy = DeltaChain(
      rolloverWhen: DeltaRatio(over: double.parse(rollover)),
    );
  }
  final receipt = store.record(
    bytes,
    name: name,
    policy: strategy,
    codec: codec ?? const ZstdCliCodec(),
  );
  stdout.writeln(
    results['json'] as bool
        ? const JsonEncoder.withIndent(' ').convert(receipt.toJson())
        : receipt.toString(),
  );

  final pointerPath = results['pointer'] as String?;
  if (pointerPath != null) {
    ArtifactPointer(
      name: name,
      sha256: receipt.sha256,
      backend: (results['backend'] as String?) ?? 'local',
      sdkVersion: (results['sdk'] as String?) ?? Platform.version,
      inputsHash:
          (results['inputs'] as String?) ??
          ArtifactPointer.hashBytes(bytes.sublist(0, bytes.length)),
      entrypoint: results['entrypoint'] as String?,
      createdAt: DateTime.now().toUtc(),
    ).writeTo(File(pointerPath));
    stdout.writeln('pointer: $pointerPath');
  }
}

void _materialize(
  final ArtifactStore store,
  final DeltaCodec? codec,
  final ArgResults results,
  final List<String> args,
) {
  final name = results['name'] as String? ?? (args.length > 1 ? args[1] : null);
  if (name == null) {
    stderr.writeln('usage: materialize <name> [-o <file>]');
    exitCode = 2;
    return;
  }
  try {
    final result = store.materialize(name: name, codec: codec);
    final out = results['out'] as String?;
    if (out != null) {
      File(out)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(result.bytes);
      stdout.writeln('${result.sha256} -> $out');
    } else {
      stdout.writeln('${result.sha256} (${result.bytes.length} bytes)');
    }
  } on ArtifactStoreCorruptException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
    // The store names a missing chain with StateError; this CLI boundary
    // turns it into an exit code.
    // ignore: avoid_catching_errors
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

void _verify(
  final ArtifactStore store,
  final DeltaCodec? codec,
  final ArgResults results,
  final List<String> args,
) {
  final name = results['name'] as String? ?? (args.length > 1 ? args[1] : null);
  if (name == null) {
    stderr.writeln('usage: verify <name>');
    exitCode = 2;
    return;
  }
  // A missing chain is a caller error (exit 1), not a crash. The
  // store's contract names absence via StateError (documented);
  // pre-checking would duplicate lib error strings and race the read.
  final VerifyReport report;
  try {
    report = store.verify(name: name, codec: codec);
    // ignore: avoid_catching_errors
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
    return;
  }
  stdout.writeln(
    results['json'] as bool
        ? '{"ok": ${report.ok}, "problems": '
              '${const JsonEncoder.withIndent(" ").convert(report.problems)}}'
        : (report.ok
              ? 'ok: $name'
              : 'corrupt: $name\n'
                    '${report.problems.map((final p) => '  - $p').join('\n')}'),
  );
  if (!report.ok) exitCode = 1;
}

void _status(
  final ArtifactStore store,
  final ArgResults results,
  final List<String> args,
) {
  final name = results['name'] as String? ?? (args.length > 1 ? args[1] : null);
  if (name != null) {
    final status = store.status(name: name);
    stdout.writeln(status == null ? 'no chain for "$name"' : _pretty(status));
    return;
  }
  final names = store.names();
  stdout.writeln(names.isEmpty ? 'store is empty' : names.join('\n'));
}

String _pretty(final Map<String, Object?> value) =>
    const JsonEncoder.withIndent('  ').convert(value);

const String _usage =
    'oka_artifacts — content-addressed artifact store '
    'with delta chains (ADR-0043)\n'
    '  put <file> --name <n>       record a revision (dedup by hash)\n'
    '  materialize <name> [-o f]   walk the chain to full bytes\n'
    '  verify <name>               integrity-check every link\n'
    '  status [name]               chain summary or store listing';
