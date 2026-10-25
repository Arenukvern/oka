/// Dependency-declared consumer ProGuard rules (ADR-0051).
///
/// Every Android AAR may ship a `proguard.txt` archive entry: the
/// *consumer rules* the library author declares for apps that depend on it.
/// The Android Gradle Plugin aggregates those files from every dependency
/// AAR and feeds them to R8 — that is the only mechanism through which a
/// library can declare "these classes are optional for me" (e.g.
/// `play-services-basement` declares `-dontwarn javax.annotation.**` because
/// its annotation-only dependencies are not on the runtime classpath).
///
/// oka's no-Gradle pipeline extracted `classes.jar`, `jni/` and `res/` from an
/// AAR but dropped `proguard.txt`, so a release build failed in R8 with
/// "Missing class …" for classes every declared dependency already declared
/// optional. This module reads those rules back from the resolved artifacts
/// and hands them to the shrinker, with the same semantics as AGP:
///
/// * only rules of artifacts that are actually on the program classpath
///   apply (one rule set per artifact, newest version wins — the same
///   selection `filterRuntimeJars` performs for the bytecode);
/// * the rules are fed to R8 as one rule file in a deterministic position of
///   the input order (after oka's own defaults, before the project's own
///   rules). That order is *not* a precedence mechanism: `-keep` and
///   `-dontwarn` directives accumulate across the rule files, so an app rule
///   does not undo a library's suppression or keep.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'plugin_consumer_rules.dart';

/// Consumer ProGuard rules declared by one dependency artifact.
class ConsumerProguardRules {
  const ConsumerProguardRules({
    required this.coordinate,
    required this.source,
    required this.rules,
  });

  /// `group:artifact:version` of the declaring artifact (best effort).
  final String coordinate;

  /// Where the rules were read from (the AAR, or its extracted payload copy).
  final String source;

  /// The verbatim rule text.
  final String rules;

  @override
  String toString() => 'ConsumerProguardRules($coordinate)';
}

/// AAR archive entry that holds the consumer rules.
const consumerRulesEntryName = 'proguard.txt';

/// The AAR a `classes.jar` was extracted from, or null when the jar did not
/// come from an AAR (plain Maven jar) or the AAR is no longer cached.
///
/// The Maven store keeps the AAR next to the extracted classes jar:
/// `<store>/<group>/<artifact>/<version>/<artifact>-<version>.aar` beside
/// `<artifact>-<version>-classes.jar`.
String? aarPathForClassesJar(String classesJarPath) {
  final name = p.basename(classesJarPath);
  const suffix = '-classes.jar';
  if (!name.endsWith(suffix)) return null;
  final aarName = '${name.substring(0, name.length - suffix.length)}.aar';
  return p.join(p.dirname(classesJarPath), aarName);
}

/// Reads the consumer rules of the AAR [classesJarPath] was extracted from.
///
/// Returns null when the artifact has no consumer rules (plain jar, metadata
/// AAR, or the AAR is not cached anymore). The AAR is the source of truth;
/// the extracted copies are fallbacks for stores where the AAR was pruned
/// but its payload survived (`<dir>/payload/proguard.txt`) and for
/// project-local AARs, whose payload is extracted next to the classes jar
/// (`<dir>/proguard.txt`).
String? readConsumerProguardRules(String classesJarPath) {
  final aarPath = aarPathForClassesJar(classesJarPath);
  if (aarPath != null) {
    final aar = File(aarPath);
    if (aar.existsSync()) {
      final rules = _consumerRulesFromAar(aar.readAsBytesSync());
      if (rules != null && rules.trim().isNotEmpty) return rules;
    }
  }
  final dir = p.dirname(classesJarPath);
  for (final candidate in [
    p.join(dir, 'payload', consumerRulesEntryName),
    p.join(dir, consumerRulesEntryName),
  ]) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync();
    if (text.trim().isNotEmpty) return text;
  }
  return null;
}

/// Extracts the `proguard.txt` entry of an AAR archive.
String? _consumerRulesFromAar(List<int> aarBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(aarBytes);
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll(r'\', '/');
      if (name == consumerRulesEntryName ||
          name.endsWith('/$consumerRulesEntryName')) {
        return String.fromCharCodes(file.content as List<int>);
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Collects the consumer rules of every AAR-backed jar in [runtimeJars].
///
/// Jars that were not extracted from an AAR, or that declare no consumer
/// rules, contribute nothing. The result keeps the input order so the
/// generated rule file is stable across builds.
List<ConsumerProguardRules> collectConsumerProguardRules(
  Iterable<String> runtimeJars,
) {
  final out = <ConsumerProguardRules>[];
  final seen = <String>{};
  for (final jar in runtimeJars) {
    final rules = readConsumerProguardRules(jar);
    if (rules == null) continue;
    final coordinate = mavenCoordinateForStorePath(jar);
    if (!seen.add(coordinate)) continue;
    out.add(
      ConsumerProguardRules(
        coordinate: coordinate,
        source: aarPathForClassesJar(jar) ?? jar,
        rules: rules,
      ),
    );
  }
  return out;
}

/// Reads the consumer rules of explicitly declared rule files — the
/// `consumerProguardFiles` a *source* Flutter plugin declares in its Gradle
/// script (ADR-0051). A source plugin is compiled from source, so it ships
/// no AAR with a `proguard.txt`; the declaration is the only place its
/// consumer rules exist.
///
/// The owner (the plugin name) is the attribution, and the order is
/// deterministic: by owner, then by path.
List<ConsumerProguardRules> collectConsumerProguardRuleFiles(
  Iterable<PluginConsumerRuleFile> files,
) {
  final out = <ConsumerProguardRules>[];
  final seen = <String>{};
  final ordered = files.toList()
    ..sort((a, b) {
      final byOwner = a.pluginName.compareTo(b.pluginName);
      return byOwner != 0 ? byOwner : a.path.compareTo(b.path);
    });
  for (final file in ordered) {
    if (!seen.add('${file.pluginName}|${file.path}')) continue;
    final content = File(file.path);
    if (!content.existsSync()) continue;
    final text = content.readAsStringSync();
    if (text.trim().isEmpty) continue;
    out.add(
      ConsumerProguardRules(
        coordinate: file.pluginName,
        source: file.path,
        rules: text,
      ),
    );
  }
  return out;
}

/// Best-effort `group:artifact:version` for a jar inside the Maven store.
///
/// The store layout is `<root>/<group path>/<artifact>/<version>/<file>`; the
/// group path starts after the `maven`/`cache` segment. Paths outside the
/// store (project-local jars) fall back to the file name.
String mavenCoordinateForStorePath(String jarPath) {
  final parts = p.split(jarPath);
  if (parts.length < 4) return p.basename(jarPath);
  final version = parts[parts.length - 2];
  final artifact = parts[parts.length - 3];
  final group = <String>[];
  for (var i = parts.length - 4; i >= 0; i--) {
    if (parts[i] == 'maven' || parts[i] == 'cache') break;
    group.insert(0, parts[i]);
  }
  if (group.isEmpty) return '$artifact:$version';
  return '${group.join('.')}:$artifact:$version';
}

/// Renders collected consumer rules into one ProGuard rule file.
///
/// Each block keeps its declaring artifact as a comment so the release
/// evidence shows which library declared which rule.
String renderConsumerProguardRules(List<ConsumerProguardRules> rules) {
  final buffer = StringBuffer(
    '# Consumer ProGuard rules declared by the dependencies (ADR-0051).\n'
    '# Verbatim declarations, one block per artifact: the `proguard.txt`\n'
    '# shipped inside an AAR, or the `consumerProguardFiles` a source plugin\n'
    '# declares in its Gradle script. The same aggregation the Android\n'
    '# Gradle Plugin performs for library consumers.\n',
  );
  for (final entry in rules) {
    buffer.writeln();
    buffer.writeln('# --- ${entry.coordinate} ---');
    buffer.writeln(entry.rules.trim());
  }
  return buffer.toString();
}
