/// Shell pipeline steps (ADR-0016 §2): validate → emit (→ zip).
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../composition.dart';
import '../emitter.dart';
import '../validation.dart';

/// Validates the composed shell (pure issues + icon existence), then
/// provides the composed shell downstream (ADR-0016: validation before
/// any I/O / emit).
class ValidateWebShellStep extends BuildStep {
  ValidateWebShellStep({required this.shell, required this.webDir});

  /// The composed-shell artifact consumed by [EmitWebShellStep].
  static const webShellComposed = Artifact<WebShell>('web-shell');

  /// The composed shell to validate.
  final WebShell shell;

  /// Absolute web directory (icon paths resolve under it).
  final String webDir;

  @override
  String get name => 'validate-web-shell';

  @override
  Set<Artifact<Object>> get provides => {webShellComposed};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final issues = validateWebShell(shell, webDir: webDir);
    if (issues.isNotEmpty) {
      return StepResult.failure(
        'web shell validation failed:\n'
        '${issues.map((final i) => '  - $i').join('\n')}',
      );
    }
    state[webShellComposed.id] = shell;
    return StepResult.success({'web-shell': shell.describeLines().join('\n')});
  }
}

/// Renders the composed shell via the configured emitter and writes the
/// output files. I/O lives ONLY here — emitters are pure string
/// renderers (ADR-0016).
class EmitWebShellStep extends BuildStep {
  EmitWebShellStep({required this.emitter, required this.webDir});

  /// Written file paths (web-dir-relative), e.g. `index.html`.
  static const webShellFiles = Artifact<List<String>>('web-shell-files');

  /// The absolute web directory the files were written to. Consumed by
  /// [WebZipStep] (directory-artifact convention, ADR-0016 §2).
  static const webDirArtifact = Artifact<String>('web-dir');

  /// The emitter to render with (generate by default, inject for legacy
  /// files, custom per project).
  final ShellEmitter emitter;

  /// Absolute web directory to write into (created if missing).
  final String webDir;

  @override
  String get name => 'emit-web-shell';

  @override
  Set<Artifact<Object>> get requires => {ValidateWebShellStep.webShellComposed};

  @override
  Set<Artifact<Object>> get provides => {webShellFiles, webDirArtifact};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final shell = state[ValidateWebShellStep.webShellComposed.id];
    if (shell is! WebShell) {
      return StepResult.failure(
        'artifact "${ValidateWebShellStep.webShellComposed.id}" is missing '
        'or not a WebShell — run ValidateWebShellStep first',
      );
    }
    String? existingIndexHtml;
    final existing = File(p.join(webDir, 'index.html'));
    if (existing.existsSync()) existingIndexHtml = existing.readAsStringSync();

    late final ShellOutput output;
    try {
      output = emitter.emit(shell, existingIndexHtml: existingIndexHtml);
    } on ShellInjectionException catch (e) {
      return StepResult.failure(e.message);
    }

    Directory(webDir).createSync(recursive: true);
    final written = <String>[];
    for (final entry in output.files.entries) {
      final file = File(p.join(webDir, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
      written.add(entry.key);
    }
    state[webShellFiles.id] = List<String>.unmodifiable(written);
    state[webDirArtifact.id] = webDir;
    return StepResult.success({
      'emitter': emitter.name,
      'web-shell-files': written.join(', '),
      // The composed shell render — what `oka explain` shows before
      // anything is written (ADR-0016 W1 wires explain to this).
      'web-shell': shell.describeLines().join('\n'),
      'notes': output.notes.join('\n'),
    });
  }
}
