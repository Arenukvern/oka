/// Declared Flutter app under test / dev.
library;

import 'package:meta/meta.dart';

import 'spec_violation.dart';

/// Build/launch surface for a dev session (install/attach wiring is R4+).
@immutable
final class AppSpec with TypedSpec {
  const AppSpec({
    required this.projectPath,
    this.entrypoint = 'lib/main.dart',
    this.defines = const {},
  });

  final String projectPath;
  final String entrypoint;
  final Map<String, String> defines;

  @override
  List<String> validate() {
    final problems = <String>[];
    if (projectPath.trim().isEmpty) {
      problems.add('app.projectPath must not be empty');
    }
    if (entrypoint.trim().isEmpty) {
      problems.add('app.entrypoint must not be empty');
    }
    for (final entry in defines.entries) {
      if (entry.key.trim().isEmpty) {
        problems.add('app.defines contains an empty key');
      }
    }
    return problems;
  }
}
