/// Declared Android Virtual Device shape.
library;

import 'package:meta/meta.dart';

import 'spec_violation.dart';

/// Immutable AVD declaration (provisioning is R6+).
@immutable
final class AvdSpec with TypedSpec {
  const AvdSpec({required this.name});

  /// `emulator -avd <name>`.
  final String name;

  @override
  List<String> validate() {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return ['avd.name must not be empty'];
    }
    return const [];
  }
}
