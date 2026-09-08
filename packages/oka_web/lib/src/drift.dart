/// The W1 drift gate (ADR-0016): a **pure** comparator between a composed
/// shell and the on-disk contents of the emitter's owned paths.
///
/// The law: everything a [ShellEmitter] declares as owned
/// ([ShellEmitter.ownedPaths]) must be exactly the re-render of the
/// composed [WebShell] — a no-op re-emission. If re-rendering the shell
/// does not reproduce the file byte-for-byte, the file has drifted from
/// the composition (hand-edits inside an owned region, a stale emit, or
/// an emitter that is not a pure function of its inputs) and the gate
/// reports it with an actionable message.
///
/// No I/O lives here: the caller (a step, a CLI check) reads the owned
/// paths from disk and passes their contents in as strings
/// ([checkShellDrift.currentFiles], `null` = missing on disk). The
/// comparison itself is a pure function over strings, so `oka explain`
/// and tests can run it without touching the filesystem.
library;

import 'package:meta/meta.dart';

import 'composition.dart';
import 'emitter.dart';

/// One drifted owned path, with an actionable message.
@immutable
class ShellDrift {
  const ShellDrift({required this.path, required this.message});

  /// Web-directory-relative path that drifted (e.g. `index.html`).
  final String path;

  /// What's owned, what differs, what to run.
  final String message;

  @override
  String toString() => '$path: $message';
}

/// The result of [checkShellDrift]: clean, or a list of per-path drifts.
@immutable
class ShellDriftReport {
  const ShellDriftReport({
    required this.emitterName,
    this.drifts = const [],
  });

  /// Name of the emitter the check ran against.
  final String emitterName;

  /// One entry per drifted owned path; empty when clean.
  final List<ShellDrift> drifts;

  /// `true` when every owned path is exactly the composition's render.
  bool get isClean => drifts.isEmpty;

  /// Human/agent-readable report lines (what's owned, what differs, what
  /// to run).
  List<String> describeLines() {
    const runHint = 'Run `oka run web-shell` to re-emit, after fixing the '
        'cause (edit the composition — WebShellSpec / contributions — not '
        'the emitted region).';
    if (isClean) {
      final cleanLine = 'drift gate: clean — owned paths of emitter '
          '"$emitterName" match the composition re-render';
      return [cleanLine];
    }
    final header = 'drift gate: ${drifts.length} drifted path(s) owned by '
        'emitter "$emitterName" — re-rendering the composed shell does not '
        'reproduce the files on disk:';
    return [
      header,
      for (final drift in drifts) ...[
        '  ${drift.path}:',
        ...drift.message.split('\n').map((final l) => '    $l'),
      ],
      runHint,
    ];
  }

  @override
  String toString() => describeLines().join('\n');
}

/// Pure drift gate: re-renders [shell] with [emitter] and compares the
/// re-render against [currentFiles] — the current on-disk contents of the
/// emitter's owned paths (web-dir-relative path → content; `null` = the
/// path does not exist on disk).
///
/// Uniform no-op law, per emitter:
///
/// - **generate** (owns whole files): `emit(shell, existingIndexHtml:
///   disk)` ignores the existing file, so the comparison is "owned file ==
///   full render".
/// - **inject** (owns only the marker regions): `emit(shell,
///   existingIndexHtml: disk)` re-renders the composition into the
///   on-disk file's marker regions; the comparison is "re-emission is a
///   no-op on the current file" — i.e. the marker regions already match
///   the composition and everything outside them is untouched.
///
/// A missing owned path, an unrenderable owned path (emitter declared
/// ownership but produced no file), or a failed injection (markers absent
/// or unbalanced) are all reported as drift with the emitter's actionable
/// message.
ShellDriftReport checkShellDrift({
  required final WebShell shell,
  required final ShellEmitter emitter,
  required final Map<String, String?> currentFiles,
}) {
  final ShellOutput output;
  try {
    output = emitter.emit(
      shell,
      existingIndexHtml: currentFiles['index.html'],
    );
  } on ShellInjectionException catch (e) {
    return ShellDriftReport(
      emitterName: emitter.name,
      drifts: [
        ShellDrift(
          path: 'index.html',
          message: 'the ${emitter.name} emitter cannot re-render its owned '
              'region:\n${e.message}',
        ),
      ],
    );
  }

  final drifts = <ShellDrift>[];
  for (final owned in emitter.ownedPaths) {
    final disk = currentFiles[owned];
    if (disk == null) {
      drifts.add(
        ShellDrift(
          path: owned,
          message: 'owned by the "${emitter.name}" emitter but missing on '
              'disk — run `oka run web-shell` to emit it',
        ),
      );
      continue;
    }
    final rendered = output.files[owned];
    if (rendered == null) {
      drifts.add(
        ShellDrift(
          path: owned,
          message: 'declared in the "${emitter.name}" emitter\'s ownedPaths '
              'but the emitter does not render it — this is an emitter bug '
              '(ownedPaths must exactly match the emitted files)',
        ),
      );
      continue;
    }
    if (rendered != disk) {
      drifts.add(
        ShellDrift(
          path: owned,
          message: _driftMessage(
            emitterName: emitter.name,
            rendered: rendered,
            disk: disk,
          ),
        ),
      );
    }
  }
  return ShellDriftReport(emitterName: emitter.name, drifts: drifts);
}

/// Actionable drift detail: what's owned, what differs (lengths + first
/// differing line), what to run.
String _driftMessage({
  required final String emitterName,
  required final String rendered,
  required final String disk,
}) {
  final diff = _firstLineDiff(rendered, disk);
  return 'owned by the "$emitterName" emitter; the file on disk differs '
      'from the composition re-render '
      '(re-render: ${rendered.length} bytes, disk: ${disk.length} bytes'
      '${diff == null ? '' : '; first difference: $diff'}).\n'
      'The file (or, for the `inject` emitter, its oka marker regions) is '
      'owned by the web shell station — edit the composition '
      '(WebShellSpec / WebShellContribution values), never the emitted '
      'region, then run `oka run web-shell` to re-emit.';
}

/// First differing line between two strings, as a short human hint.
String? _firstLineDiff(final String a, final String b) {
  final aLines = a.split('\n');
  final bLines = b.split('\n');
  final n = aLines.length < bLines.length ? aLines.length : bLines.length;
  for (var i = 0; i < n; i++) {
    if (aLines[i] != bLines[i]) {
      return 'line ${i + 1} — '
          'expected "${_clip(aLines[i])}", '
          'found "${_clip(bLines[i])}"';
    }
  }
  if (aLines.length != bLines.length) {
    return 'line count differs (expected ${aLines.length}, '
        'found ${bLines.length})';
  }
  return null;
}

String _clip(final String line) {
  final one = line.trim();
  return one.length <= 60 ? one : '${one.substring(0, 57)}…';
}
