/// Named, app-local plan storage: the device-local authoring tier of the
/// adoption ladder (ADR-0041).
///
/// An embedding app (e.g. Last Answer) saves user-authored automations as
/// plan documents under `<root>/<name>.json` — atomic writes, the same
/// law as the machine registry. Repo-governed plans stay in git and are
/// loaded directly; this store is only the on-device half.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'codec.dart';
import 'spec.dart';

/// A directory of named plan documents.
final class SpecStore {
  SpecStore(this.root) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  /// The default on-device store for [appId]:
  /// `~/.oka/supervisor/plans/<appId>`.
  factory SpecStore.forAppId(final String appId) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'HOME is not set; cannot locate ~/.oka/supervisor/plans',
      );
    }
    return SpecStore(
      Directory(p.join(home, '.oka', 'supervisor', 'plans', appId)),
    );
  }

  /// The store directory; created on construction.
  final Directory root;

  Directory get dir => root;

  /// Loads [name]; `null` when absent. Throws [SpecFormatException] on an
  /// unparseable document — corrupt plans are surfaced, never ignored.
  DesiredState? load(final String name) {
    final file = _file(name);
    if (!file.existsSync()) return null;
    return const SpecCodec().decode(file.readAsStringSync());
  }

  /// Saves [desired] atomically (temp + rename), creating parents.
  void save(final String name, final DesiredState desired) {
    final file = _file(name);
    file.parent.createSync(recursive: true);
    File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp')
      ..writeAsStringSync('${const SpecCodec().encode(desired)}\n')
      ..renameSync(file.path);
  }

  /// Stored plan names (sorted, `.json` stripped).
  List<String> names() {
    if (!dir.existsSync()) return const <String>[];
    final names = <String>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      names.add(p.basenameWithoutExtension(entity.path));
    }
    return names..sort();
  }

  /// Deletes [name]; a missing plan is not an error.
  void delete(final String name) {
    final file = _file(name);
    if (file.existsSync()) file.deleteSync();
  }

  File _file(final String name) {
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      throw ArgumentError('invalid plan name: "$name"');
    }
    return File(p.join(dir.path, '$name.json'));
  }
}
