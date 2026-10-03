/// Gate 1 helper: load a kernel dill through pkg/kernel (+ pkg/vm metadata
/// repositories), inspect it, and re-serialize it losslessly (verified by
/// re-read). Status after the 2026-10-02 runs: dart-side round-trip is
/// lossless, but gen_snapshot still refuses the re-serialized dill
/// ("Missing table selector metadata") — see ADR-0032 G1/G1b. The working
/// discoveries, each required for losslessness:
///
/// 1. Plain BinaryBuilder (and `loadComponentFromBytes`) silently drops EVERY
///    metadata subsection — only `BinaryBuilderWithMetadata` reads them.
/// 2. All twelve VM metadata repositories must be registered on the
///    component before reading; unregistered subsections vanish.
/// 3. `disableLazyReading: true` is required for metadata attach + write
///    lookups to materialize.
/// 4. kernel's `expectedSdkHash` is a compile-time `-Dsdk_hash` constant;
///    a from-source compile writes `0000000000` and C++ backends gate on it —
///    carry the input dill's hash through.
///
/// Run with a package_config that maps `kernel` and `vm` to a pinned SDK
/// checkout (see tool/gate1_roundtrip.sh).
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:vm/metadata/closure_id.dart';
import 'package:vm/metadata/direct_call.dart';
import 'package:vm/metadata/inferred_type.dart';
import 'package:vm/metadata/loading_units.dart';
import 'package:vm/metadata/obfuscation_prohibitions.dart';
import 'package:vm/metadata/procedure_attributes.dart';
import 'package:vm/metadata/table_selector.dart';
import 'package:vm/metadata/unboxing_info.dart';
import 'package:vm/metadata/unreachable.dart';
// call-site-attributes lives under modular/ in this SDK version.
import 'package:vm/modular/metadata/call_site_attributes.dart';

final _sdkPrefix = RegExp('^dart:');

class _ByteSink implements Sink<List<int>> {
  final _builder = BytesBuilder();
  @override
  void add(List<int> chunk) => _builder.add(chunk);
  @override
  void close() {}
  Uint8List take() => _builder.takeBytes();
}

Component _componentWithVmMetadata() {
  final component = Component();
  final repos = <MetadataRepository<dynamic>>[
    CallSiteAttributesMetadataRepository(),
    ClosureIdMetadataRepository(),
    DirectCallMetadataRepository(),
    InferredTypeMetadataRepository(),
    InferredArgTypeMetadataRepository(),
    InferredReturnTypeMetadataRepository(),
    LoadingUnitsMetadataRepository(),
    ObfuscationProhibitionsMetadataRepository(),
    ProcedureAttributesMetadataRepository(),
    TableSelectorMetadataRepository(),
    UnboxingInfoMetadataRepository(),
    UnreachableNodeMetadataRepository(),
  ];
  for (final repo in repos) {
    component.metadata[repo.tag] = repo;
  }
  return component;
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: kernel_roundtrip.dart <in.dill> <out.dill>');
    exitCode = 2;
    return;
  }
  final bytes = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final component = _componentWithVmMetadata();
  // Plain BinaryBuilder (and loadComponentFromBytes) never reads metadata
  // mappings; BinaryBuilderWithMetadata attaches them to the registered
  // repositories. disableLazyReading materializes nodes eagerly so the
  // writer's `repository.mapping[node]` lookups hit during serialization.
  BinaryBuilderWithMetadata(bytes, disableLazyReading: true)
      .readComponent(component);

  final own = component.libraries
      .where((l) => !_sdkPrefix.hasMatch(l.importUri.toString()))
      .map((l) => l.importUri.toString())
      .toList()
    ..sort();
  // NOTE: kernel's AST carries no `deferred` flag on libraries; deferred-ness
  // is encoded at the dill/LibraryDependency layer — a Gate 2 (transform)
  // concern, introspected there.
  stdout.writeln('libraries total: ${component.libraries.length}');
  stdout.writeln('non-sdk libraries: $own');
  stdout.writeln('metadata repositories: ${component.metadata.keys.toList()..sort()}');
  final lengths = component.metadata.values
      .map((r) => '${r.tag}: ${r.mapping.length}')
      .toList()
    ..sort();
  stdout.writeln('metadata mapping sizes: $lengths');

  final sink = _ByteSink();
  final printer = BinaryPrinter(sink);
  printer.writeComponentFile(component);
  File(args[1]).writeAsBytesSync(sink.take());
  stdout.writeln('round-tripped: ${args[1]}');

  // Verify fidelity: re-read the output and report mapping sizes again.
  final verify = _componentWithVmMetadata();
  BinaryBuilderWithMetadata(
    Uint8List.fromList(File(args[1]).readAsBytesSync()),
    disableLazyReading: true,
  ).readComponent(verify);
  final verifySizes = verify.metadata.values
      .map((r) => '${r.tag}: ${r.mapping.length}')
      .toList()
    ..sort();
  stdout.writeln('verify mapping sizes: $verifySizes');
  final ts = component.metadata['vm.table-selector.metadata'];
  if (ts != null && ts.mapping.isNotEmpty) {
    final key = ts.mapping.keys.first;
    stdout.writeln('table-selector key type: ${key.runtimeType}');
    stdout.writeln(
      'table-selector value type: ${ts.mapping.values.first.runtimeType}',
    );
  }
}
