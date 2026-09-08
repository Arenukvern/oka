/// The emitter seam (ADR-0016): the "how" — a replaceable renderer of the
/// composed shell.
///
/// The emitter is fully responsible for rendering the composed shell and
/// **declares what it owns** ([ShellEmitter.ownedPaths]); the W1 drift gate
/// validates owned regions against the composition. Three implementation
/// classes exist from day one: [GenerateShellEmitter] (default, oka owns
/// `web/index.html` + `web/manifest.json`), [InjectShellEmitter]
/// (first-party migration path for hand-maintained files), and custom
/// project emitters — the contribution contract stays stable across all
/// of them.
library;

import 'package:meta/meta.dart';

import 'composition.dart';

/// What an emitter produced: rendered files (relative to the web
/// directory) plus notes for the plan/summary.
@immutable
class ShellOutput {
  /// Const constructor; [files] is required, [notes] defaults to empty.
  const ShellOutput({required this.files, this.notes = const []});

  /// Rendered files, keyed by web-directory-relative path (e.g.
  /// `index.html`, `manifest.json`).
  final Map<String, String> files;

  /// Non-fatal notes (what was injected, what was preserved).
  final List<String> notes;

  /// Debug string: the owned file keys.
  @override
  String toString() => 'ShellOutput(${files.keys.join(', ')})';
}

/// Thrown by [ShellEmitter] implementations when injection is impossible
/// (markers absent, unbalanced, or the file missing). Carries an
/// actionable, user-facing message — catch and print, never swallow.
class ShellInjectionException implements Exception {
  /// Carries the actionable, user-facing message.
  const ShellInjectionException(this.message);

  /// The actionable message (includes how to fix).
  final String message;

  /// The message itself — print this, don't wrap it.
  @override
  String toString() => message;
}

/// The "how" seam: renders a composed [WebShell] (ADR-0016 §1).
///
/// Implementations must be pure string renderers — no I/O — so
/// [EmitWebShellStep] owns writing and `oka explain` can render the shell
/// without touching the filesystem.
///
/// ```dart
/// class MyEmitter extends ShellEmitter {
///   @override
///   String get name => 'my-emitter';
///   @override
///   Set<String> get ownedPaths => {'web/index.html'};
///   @override
///   ShellOutput emit(WebShell shell, {String? existingIndexHtml}) => ...;
/// }
/// ```
abstract class ShellEmitter {
  /// Const constructor for const emitter instances.
  const ShellEmitter();

  /// Stable emitter name (config surface: `emitter:`).
  String get name;

  /// Paths this emitter owns (web-dir-relative), used by the W1 drift
  /// gate to validate owned regions against the composition.
  Set<String> get ownedPaths;

  /// Renders the composed [shell].
  ///
  /// [existingIndexHtml] carries the current `web/index.html` content for
  /// emitters that inject (null when the file does not exist).
  ShellOutput emit(final WebShell shell, {final String? existingIndexHtml});
}
