/// Emits an S2 slot registry from a JSON provision spec (`tool/` driver;
/// the library itself is pure — `lib/src/slot_registry.dart`).
///
/// Usage: `dart run tool/emit_slot_registry.dart --spec file.json --out
/// generated.dart`. Spec shape:
/// `{"families": [{"name": "feature", "contractType": "String Function()",
/// "revisions": [{"id": "r1", "importUri": "units/feature_r1.dart",
/// "member": "feature"}]}]}`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';

Future<void> main(List<String> args) async {
  String? specPath;
  String? outPath;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--spec':
        specPath = args[++i];
      case '--out':
        outPath = args[++i];
    }
  }
  if (specPath == null || outPath == null) {
    stderr.writeln('usage: dart run tool/emit_slot_registry.dart '
        '--spec <file.json> --out <generated.dart>');
    exitCode = 64;
    return;
  }
  final spec =
      jsonDecode(File(specPath).readAsStringSync()) as Map<String, dynamic>;
  final provision = SlotProvision(families: [
    for (final family in (spec['families'] as List).cast<Map<String, dynamic>>())
      SlotFamily(
        name: family['name']! as String,
        contractType: family['contractType']! as String,
        revisions: [
          for (final revision
              in (family['revisions'] as List).cast<Map<String, dynamic>>())
            SlotRevision(
              id: revision['id']! as String,
              importUri: revision['importUri']! as String,
              member: revision['member']! as String,
            ),
        ],
      ),
  ]);
  File(outPath).writeAsStringSync(emitSlotRegistrySource(provision));
  stdout.writeln('slot-registry: wrote $outPath '
      '(${provision.families.length} families)');
}
