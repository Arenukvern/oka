/// The boot watchdog (ADR-0037 G-AC6, client half): a staged update set
/// is journaled before it takes effect; the app's startup beacon decides
/// between `commit` (promote staged → current) and `rollback` (discard
/// staged, keep the known-good set). A staged update can never brick an
/// install: the previous set stays on disk until the beacon says the new
/// one booted.
library;

import 'dart:convert';
import 'dart:io';

import 'update_client.dart' show UpdateReceipt;

/// Where the journal keeps its state: `<root>/journal.json`, plus
/// `current/` (known good) and `staged/` (candidate) directories.
class StagedUpdateJournal {
  StagedUpdateJournal(this.root);

  static const int schemaVersion = 1;

  final String root;

  File get _journalFile => File('$root/journal.json');
  Directory get _currentDir => Directory('$root/current');
  Directory get _stagedDir => Directory('$root/staged');

  /// Reads the journal; a missing journal means a fresh install
  /// (nothing staged, nothing current).
  JournalState read() {
    if (!_journalFile.existsSync()) {
      return const JournalState();
    }
    try {
      final json = (jsonDecode(_journalFile.readAsStringSync()) as Map)
          .cast<String, dynamic>();
      return JournalState(
        current: json['current'] as String?,
        staged: json['staged'] as String?,
        revision: json['revision'] as String?,
        dirty: json['dirty'] == true,
      );
    } on FormatException {
      // A corrupt journal is a dirty state, never a crash.
      return const JournalState(dirty: true);
    }
  }

  /// Journals a fetched [UpdateReceipt]: its staged files are copied into
  /// `<root>/staged/` and the journal flips to staged. Returns the state
  /// the target boots under.
  JournalState stage(UpdateReceipt receipt) {
    if (!receipt.ok) {
      throw ArgumentError('refusing to journal a failed receipt');
    }
    final state = read();
    _stagedDir.createSync(recursive: true);
    for (final path in receipt.stagedFiles) {
      final f = File(path);
      f.copySync('${_stagedDir.path}/${f.uri.pathSegments.last}');
    }
    return _write(
      current: state.current,
      staged: 'staged',
      revision: receipt.toRevision,
    );
  }

  /// The startup beacon fired on the staged set: promote it. The previous
  /// current is discarded by design — fleet-wide rollback is the next
  /// update's job (`oka ship --rollback` repoints the channel).
  JournalState commit() {
    final state = read();
    if (state.staged == null) return state;
    if (_currentDir.existsSync()) {
      _currentDir.deleteSync(recursive: true);
    }
    if (_stagedDir.existsSync()) {
      _stagedDir.renameSync(_currentDir.path);
    }
    return _write(current: 'current', staged: null, revision: state.revision);
  }

  /// The beacon did not fire (or probes failed): discard the staged set,
  /// keep the known-good current. Never bricks.
  JournalState rollback() {
    if (_stagedDir.existsSync()) {
      _stagedDir.deleteSync(recursive: true);
    }
    final state = read();
    return _write(
        current: state.current, staged: null, revision: state.revision);
  }

  /// The current (known-good) artifact set, when one exists.
  Directory? get currentDir =>
      _currentDir.existsSync() ? _currentDir : null;

  JournalState _write({
    required String? current,
    required String? staged,
    required String? revision,
  }) {
    Directory(root).createSync(recursive: true);
    final json = {
      'schemaVersion': schemaVersion,
      'current': current,
      'staged': staged,
      'revision': revision,
      'dirty': false,
    };
    final tmp = File('${_journalFile.path}.tmp');
    tmp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        flush: true);
    tmp.renameSync(_journalFile.path);
    return JournalState(
        current: current, staged: staged, revision: revision);
  }
}

/// The journal's durable state.
class JournalState {
  const JournalState({
    this.current,
    this.staged,
    this.revision,
    this.dirty = false,
  });

  /// The known-good set (a directory name under the journal root).
  final String? current;

  /// The candidate set awaiting the boot beacon.
  final String? staged;

  final String? revision;

  /// True when the journal was found inconsistent (interrupted run):
  /// callers should rollback before trusting anything.
  final bool dirty;

  Map<String, Object?> toJson() => {
        'current': current,
        'staged': staged,
        'revision': revision,
        'dirty': dirty,
      };
}
