/// Inspects a pipeline-produced dill: the loading-units metadata the VM
/// transformations computed, plus the deferred flags actually present on
/// dependencies targeting given URI patterns.
///
/// usage: inspect_units.dart <dill> <pattern>...
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:vm/metadata/loading_units.dart';

void main(List<String> args) {
  final component = Component();
  LoadingUnitsMetadataRepository();
  final bytes = File(args[0]).readAsBytesSync();
  BinaryBuilderWithMetadata(bytes, disableLazyReading: true)
      .readComponent(component);

  final repo = component.metadata[LoadingUnitsMetadataRepository().tag]
      as LoadingUnitsMetadataRepository?;
  final metadata = repo?.mapping[component];
  stdout.writeln(
      'loading-units metadata: ${metadata?.loadingUnits.length ?? 'MISSING'} units');
  if (metadata != null) {
    for (final u in metadata.loadingUnits) {
      stdout.writeln('  unit ${u.id} (parent ${u.parentId}): '
          '${u.libraryUris.length} libs');
    }
  }

  for (final pattern in args.sublist(1)) {
    var flagged = 0;
    var unflagged = 0;
    for (final lib in component.libraries) {
      for (final dep in lib.dependencies) {
        final target = dep.targetLibrary.importUri.toString();
        if (!target.contains(pattern)) continue;
        if (dep.isDeferred) {
          flagged++;
        } else {
          unflagged++;
          stdout.writeln('  NOT deferred: ${lib.importUri} -> $target');
        }
      }
    }
    stdout.writeln('pattern `$pattern`: $flagged deferred deps, '
        '$unflagged non-deferred');
  }
}
