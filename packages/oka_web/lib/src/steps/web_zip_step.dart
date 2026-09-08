/// The generic zip step (ADR-0016 §2): directory artifact → file artifact.
///
/// Generic on purpose — any directory artifact zips into a file artifact
/// (stores that upload zips: itch.io via butler-side packaging, VK Play,
/// Steam via app prepare). Pure Dart (`archive`), deterministic entry
/// order (sorted relative paths, ADR-0007 determinism law).
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Zips a directory artifact into a file artifact.
///
/// Artifact ids are configurable so the step stays generic; defaults
/// consume [EmitWebShellStep] outputs (`web-dir` → `web-zip-path`).
@immutable
class WebZipStep extends BuildStep {
  WebZipStep({
    this.inputArtifact = const Artifact<String>('web-dir'),
    this.outputArtifact = const Artifact<String>('web-zip-path'),
    this.outputZipPath,
  });

  /// The directory artifact to zip (defaults to the emitted web dir).
  final Artifact<String> inputArtifact;

  /// The file artifact produced (defaults to `web-zip-path`).
  final Artifact<String> outputArtifact;

  /// Explicit output zip path override (null → `<inputDir>.zip`).
  final String? outputZipPath;

  @override
  String get name => 'web-zip';

  @override
  Set<Artifact<Object>> get requires => {inputArtifact};

  @override
  Set<Artifact<Object>> get provides => {outputArtifact};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final dirPath = state[inputArtifact.id];
    if (dirPath is! String || dirPath.isEmpty) {
      return StepResult.failure(
        'artifact "${inputArtifact.id}" is missing or not a path — the zip '
        'step needs a directory artifact',
      );
    }
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      return StepResult.failure(
        'directory "$dirPath" does not exist — nothing to zip',
      );
    }

    // Deterministic artifact bytes: entry order follows sorted relative
    // paths, not filesystem directory order (ADR-0007).
    final archive = Archive();
    final entries = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        entries.add(p.relative(entity.path, from: dir.path));
      }
    }
    entries.sort();
    for (final rel in entries) {
      final data = await File(p.join(dir.path, rel)).readAsBytes();
      archive.addFile(ArchiveFile(rel, data.length, data));
    }
    final zipPath =
        outputZipPath ?? '${p.withoutExtension(dir.path)}.zip';
    await File(zipPath).parent.create(recursive: true);
    File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    state[outputArtifact.id] = zipPath;
    return StepResult.success({
      outputArtifact.id: zipPath,
      'entries': entries.length,
    });
  }
}
