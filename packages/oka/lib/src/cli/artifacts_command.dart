import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_artifacts/oka_artifacts.dart';

/// `oka artifacts` — the artifact store surface (ADR-0043): record
/// build outputs into the content-addressed store (delta chains, ratio
/// rollover) and materialize/verify them. Bytes never enter git; write
/// an [ArtifactPointer] where the binary used to be when a warm start
/// should be shared.
final class ArtifactsCommand {
  ArtifactsCommand({
    final void Function(String)? output,
    final void Function(String)? errorOutput,
    final void Function(int)? setExitCode,
    ArtifactStore? store,
  }) : _output = output ?? stdout.writeln,
       _errorOutput = errorOutput ?? stderr.writeln,
       _setExitCode = setExitCode ?? _setProcessExitCode,
       _storeOverride = store;

  final void Function(String) _output;
  final void Function(String) _errorOutput;
  final void Function(int) _setExitCode;
  final ArtifactStore? _storeOverride;

  static void _setProcessExitCode(final int value) => exitCode = value;

  Future<void> run(final List<String> args) async {
    if (args.isEmpty) {
      _output(_usage);
      return;
    }
    final parser = ArgParser()
      ..addOption('root', help: 'Store root (defaults to ~/.oka/artifacts).')
      ..addOption('name', help: 'Artifact key, e.g. app-dill.')
      ..addOption(
        'codec',
        allowed: ['zstd', 'none'],
        defaultsTo: 'zstd',
        help: 'Delta codec; none = snapshots only.',
      )
      ..addOption(
        'rollover',
        help: 'DeltaChain rollover ratio override (0..1).',
      )
      ..addOption('sdk', help: 'put: SDK version for the pointer.')
      ..addOption('inputs', help: 'put: input-set hash for the pointer.')
      ..addOption('entrypoint', help: 'put: entrypoint for the pointer.')
      ..addOption(
        'backend',
        help: 'put: backend URI for the pointer (default local).',
      )
      ..addOption('pointer', help: 'put: write an ArtifactPointer here.')
      ..addOption('out', abbr: 'o', help: 'materialize target file.')
      ..addFlag('json', negatable: false, help: 'Emit JSON.')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');
    final ArgResults results;
    try {
      results = parser.parse(args.skip(1).toList());
    } on ArgParserException catch (error) {
      _errorOutput('Invalid artifacts arguments: ${error.message}');
      _errorOutput(parser.usage);
      _setExitCode(2);
      return;
    }
    if (results['help'] as bool) {
      _output(_usage);
      _output(parser.usage);
      return;
    }
    final store = _storeOverride ?? _resolveStore(results['root'] as String?);
    final codec = (results['codec'] as String?) == 'none'
        ? null
        : const ZstdCliCodec();

    switch (args.first) {
      case 'put':
        _put(store, codec, results);
      case 'materialize':
        _materialize(store, codec, results);
      case 'verify':
        _verify(store, codec, results);
      case 'status':
        _status(store, results);
      default:
        _errorOutput(
          'Unknown artifacts command "${args.first}"; '
          'use put, materialize, verify or status.',
        );
        _setExitCode(2);
    }
  }

  ArtifactStore _resolveStore(final String? root) => root == null
      ? ArtifactStore.forMachine()
      : ArtifactStore(root: Directory(root));

  void _put(
    final ArtifactStore store,
    final DeltaCodec? codec,
    final ArgResults results,
  ) {
    final name = results['name'] as String?;
    final path = results.rest.isNotEmpty ? results.rest.first : null;
    if (name == null || path == null) {
      _errorOutput('usage: oka artifacts put <file> --name <name>');
      _setExitCode(2);
      return;
    }
    final bytes = File(path).readAsBytesSync();
    final rollover = results['rollover'] as String?;
    final strategy = rollover == null && codec == null
        ? const SnapshotOnly()
        : DeltaChain(
            rolloverWhen: rollover == null
                ? const DeltaRatio()
                : DeltaRatio(over: double.parse(rollover)),
          );
    final receipt = store.record(
      bytes,
      name: name,
      policy: strategy,
      codec: codec ?? const ZstdCliCodec(),
    );
    _emit(receipt.toJson(), results);
    final pointerPath = results['pointer'] as String?;
    if (pointerPath != null) {
      ArtifactPointer(
        name: name,
        sha256: receipt.sha256,
        backend: (results['backend'] as String?) ?? 'local',
        sdkVersion: (results['sdk'] as String?) ?? Platform.version,
        inputsHash:
            (results['inputs'] as String?) ?? ArtifactPointer.hashBytes(bytes),
        entrypoint: results['entrypoint'] as String?,
        createdAt: DateTime.now().toUtc(),
      ).writeTo(File(pointerPath));
      _output('pointer: $pointerPath');
    }
  }

  void _materialize(
    final ArtifactStore store,
    final DeltaCodec? codec,
    final ArgResults results,
  ) {
    final name = _nameOr(results);
    if (name == null) {
      _errorOutput('usage: oka artifacts materialize <name> [-o <file>]');
      _setExitCode(2);
      return;
    }
    try {
      final result = store.materialize(name: name, codec: codec);
      final out = results['out'] as String?;
      if (out != null) {
        File(out)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(result.bytes);
        _output('${result.sha256} -> $out');
      } else {
        _output('${result.sha256} (${result.bytes.length} bytes)');
      }
      // The store's contract names absence via StateError; the CLI
      // boundary converts it to an exit code.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _errorOutput(error.message);
      _setExitCode(1);
    } on ArtifactStoreCorruptException catch (error) {
      _errorOutput('$error');
      _setExitCode(1);
    }
  }

  void _verify(
    final ArtifactStore store,
    final DeltaCodec? codec,
    final ArgResults results,
  ) {
    final name = _nameOr(results);
    if (name == null) {
      _errorOutput('usage: oka artifacts verify <name>');
      _setExitCode(2);
      return;
    }
    final VerifyReport report;
    try {
      report = store.verify(name: name, codec: codec);
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _errorOutput(error.message);
      _setExitCode(1);
      return;
    }
    _output(
      (results['json'] as bool)
          ? const JsonEncoder.withIndent(
              '  ',
            ).convert({'ok': report.ok, 'problems': report.problems})
          : report.ok
          ? 'ok: $name'
          : 'corrupt: $name\n'
                '${report.problems.map((final problem) => '  - $problem').join('\n')}',
    );
    if (!report.ok) _setExitCode(1);
  }

  void _status(final ArtifactStore store, final ArgResults results) {
    final name = _nameOr(results);
    if (name != null) {
      final status = store.status(name: name);
      _output(status == null ? 'no chain for "$name"' : _pretty(status));
      return;
    }
    final names = store.names();
    _output(names.isEmpty ? 'store is empty' : names.join('\n'));
  }

  String? _nameOr(final ArgResults results) =>
      (results['name'] as String?) ??
      (results.rest.isNotEmpty ? results.rest.first : null);

  void _emit(final Map<String, Object?> value, final ArgResults results) =>
      _output((results['json'] as bool) ? _pretty(value) : _compact(value));

  String _pretty(final Map<String, Object?> value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  String _compact(final Map<String, Object?> value) =>
      value.entries.map((final e) => '${e.key}: ${e.value}').join('\n');

  static const _usage =
      'oka artifacts [put <file> | materialize <name> | verify <name> | '
      'status [name]] — content-addressed artifact store (ADR-0043)\n'
      '  put <file> --name <n>       record a revision (dedup by hash)\n'
      '  materialize <name> [-o f]   walk the chain to full bytes\n'
      '  verify <name>               integrity-check every link\n'
      '  status [name]               chain summary or store listing\n'
      'Run `oka artifacts <subcommand> --help` for flags.';
}
