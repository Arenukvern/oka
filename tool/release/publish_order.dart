// Publish-order graph for the release train (imported by train.dart and tests).

import 'dart:io';

final _pubspecSectionHeader = RegExp('^([a-z_]+):');

String _join(String first, [String? second, String? third]) {
  final parts = <String>[first];
  if (second != null) parts.add(second);
  if (third != null) parts.add(third);
  return parts.join(Platform.pathSeparator);
}

String _read(File file) =>
    file.readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\r', '\n');

Set<String> inTrainDependencies(
  File pubspec,
  Set<String> trainPackageNames,
) {
  // `dart pub publish` dry-run resolves the package as root; that graph includes
  // dev_dependencies, so in-train dev deps are publish-order constraints too.
  final deps = <String>{};
  final lines = _read(pubspec).split('\n');
  String? section;
  for (final line in lines) {
    final headerMatch = _pubspecSectionHeader.firstMatch(line);
    if (headerMatch != null) section = headerMatch.group(1);
    if (section != 'dependencies' && section != 'dev_dependencies') continue;
    final depMatch = RegExp('^  ([a-z][a-z0-9_]*):').firstMatch(line);
    if (depMatch == null) continue;
    final name = depMatch.group(1)!;
    if (trainPackageNames.contains(name)) deps.add(name);
  }
  return deps;
}

/// Topological sort of [inventory] using in-train pubspec edges; [tieBreakOrder]
/// breaks ties deterministically.
List<String> topologicalPublishOrder(
  Directory root,
  List<String> inventory,
  List<String> tieBreakOrder,
) {
  if (inventory.isEmpty) return const [];
  final trainNames = inventory.toSet();
  final tieIndex = {
    for (var index = 0; index < tieBreakOrder.length; index++)
      tieBreakOrder[index]: index,
  };
  final prerequisites = <String, Set<String>>{};
  for (final name in inventory) {
    final manifest = File(
      _join(_join(root.path, 'packages', name), 'pubspec.yaml'),
    );
    prerequisites[name] = inTrainDependencies(manifest, trainNames);
  }
  final pending = {
    for (final name in inventory) name: prerequisites[name]!.length,
  };
  final ready = [
    for (final name in inventory)
      if (pending[name]! == 0) name,
  ]..sort((a, b) => tieIndex[a]!.compareTo(tieIndex[b]!));
  final ordered = <String>[];
  while (ready.isNotEmpty) {
    final name = ready.removeAt(0);
    ordered.add(name);
    for (final other in inventory) {
      if (!prerequisites[other]!.contains(name)) continue;
      pending[other] = pending[other]! - 1;
      if (pending[other]! == 0) {
        ready.add(other);
        ready.sort((a, b) => tieIndex[a]!.compareTo(tieIndex[b]!));
      }
    }
  }
  if (ordered.length != inventory.length) {
    throw const FormatException(
      'publish order cycle among train packages (check in-train dependencies)',
    );
  }
  if (trainNames.contains('oka_process') && ordered.first != 'oka_process') {
    throw const FormatException(
      'publish order: oka_process must remain first',
    );
  }
  for (final name in inventory) {
    final index = ordered.indexOf(name);
    for (final dep in prerequisites[name]!) {
      final depIndex = ordered.indexOf(dep);
      if (depIndex >= index) {
        throw FormatException(
          'publish order violation: $name must publish after $dep',
        );
      }
    }
  }
  return ordered;
}
