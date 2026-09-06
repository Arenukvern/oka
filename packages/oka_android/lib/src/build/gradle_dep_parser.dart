/// Lightweight extraction of Maven coordinates from plugin Gradle scripts.
///
/// Handles common Groovy/Kotlin DSL patterns without running Gradle:
/// - `implementation 'group:artifact:version'`
/// - `implementation("group:artifact:version")`
/// - `api "group:artifact:version"`
/// - `compileOnly(...)` skipped for runtime packaging
library;

import 'package:meta/meta.dart';

/// A parsed dependency declaration.
@immutable
class ParsedGradleDep {

  const ParsedGradleDep({
    required this.groupId,
    required this.artifactId,
    required this.version,
    this.configuration = 'implementation',
    this.inConditional = false,
    this.conditionalGroup = 0,
  });
  final String groupId;
  final String artifactId;
  final String version;
  final String configuration; // implementation, api, etc.

  /// True when the declaration sits inside an `if (...) { ... }` block
  /// (plugin-variant conditionals, e.g. mobile_scanner's bundled/unbundled
  /// ML Kit switch). Gradle would evaluate the condition; oka cannot, so
  /// conditional variants are de-duplicated downstream
  /// (see [dedupeConditionalDeps]).
  final bool inConditional;

  /// Identifies the `if/else` group this declaration belongs to
  /// (0 when [inConditional] is false). Unique per [parseGradleDependencies]
  /// call — callers combining several files must re-map ids per file.
  final int conditionalGroup;

  String get coordinate => '$groupId:$artifactId:$version';

  @override
  String toString() => coordinate;

  @override
  bool operator ==(final Object other) =>
      other is ParsedGradleDep &&
      other.groupId == groupId &&
      other.artifactId == artifactId &&
      other.version == version;

  @override
  int get hashCode => Object.hash(groupId, artifactId, version);
}

final _coordPatterns = <RegExp>[
  // Kotlin DSL: add("implementation", "g:a:v")
  RegExp(
    r'''add\s*\(\s*["'](?:implementation|api|compileOnly|runtimeOnly|annotationProcessor)["']\s*,\s*["']([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+)["']\s*\)''',
  ),
  // Groovy/Kotlin DSL: configurations { implementation { dependencies.add("g:a:v") } }
  RegExp(
    r'''dependencies\.add\s*\(\s*["']([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+)["']\s*\)''',
  ),
  // implementation("g:a:v") or implementation('g:a:v')
  RegExp(
    r'''(?:implementation|api|compileOnly|runtimeOnly|annotationProcessor)\s*\(\s*["']([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+)["']\s*\)''',
  ),
  // implementation "g:a:v" or implementation 'g:a:v'
  RegExp(
    r'''(?:implementation|api|compileOnly|runtimeOnly)\s+["']([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+):([a-zA-Z0-9_.\-]+)["']''',
  ),
  // implementation group: 'g', name: 'a', version: 'v'
  RegExp(
    r'''(?:implementation|api)\s+group:\s*["']([^"']+)["']\s*,\s*name:\s*["']([^"']+)["']\s*,\s*version:\s*["']([^"']+)["']''',
  ),
];

/// Parse Maven coordinates from a Gradle or Gradle.kts file body.
///
/// Declarations found inside `if (...) { ... }` / `else { ... }` blocks are
/// flagged [ParsedGradleDep.inConditional] with the enclosing group id.
/// All coordinate patterns are single-line, so scopes are tracked line-wise.
List<ParsedGradleDep> parseGradleDependencies(final String gradleSource) {
  final found = <ParsedGradleDep>{};
  // Scope stack: one entry per open brace; 0 = unconditional scope,
  // >0 = inside if/else group with that id.
  final scopes = <int>[];
  var nextGroupId = 1;
  // Group id of the most recently closed if-scope, so an `else {` written on
  // its own line (after the closing `}`) rejoins the same if/else group.
  var lastClosedIfGroup = 0;

  // `if (cond) {` / `} else if (cond) {`
  final ifOpenRe = RegExp(r'^(?:\}\s*)?(?:else\s+)?if\s*\(.*\)\s*\{\s*(//.*)?$');
  // `} else {` / `else {`
  final elseOpenRe = RegExp(r'^(?:\}\s*)?else\s*\{\s*(//.*)?$');

  for (final line in gradleSource.split('\n')) {
    final trimmed = line.trim();
    final ifOpen = ifOpenRe.hasMatch(trimmed);
    final elseOpen = elseOpenRe.hasMatch(trimmed);

    if (ifOpen) {
      if (trimmed.startsWith('}') && scopes.isNotEmpty) {
        // `} else if (cond) {` — previous branch ends here.
        final popped = scopes.removeLast();
        if (popped > 0) {
          lastClosedIfGroup = popped;
        }
      }
      scopes.add(nextGroupId++);
    } else if (elseOpen) {
      if (trimmed.startsWith('}') && scopes.isNotEmpty) {
        final popped = scopes.removeLast();
        if (popped > 0) {
          lastClosedIfGroup = popped;
        }
      }
      // Continue the if/else chain under the same group id.
      scopes.add(lastClosedIfGroup > 0 ? lastClosedIfGroup : 0);
    }

    final innermostGroup = scopes.lastWhere((final g) => g > 0, orElse: () => 0);

    for (final re in _coordPatterns) {
      for (final m in re.allMatches(line)) {
        final group = m.group(1)!;
        final artifact = m.group(2)!;
        final version = m.group(3)!;
        // Skip project-local and incomplete versions
        if (version.contains(r'$') || version == '+' ) {
          continue;
        }
        if (group == 'project') {
          continue;
        }
        found.add(ParsedGradleDep(
          groupId: group,
          artifactId: artifact,
          version: version,
          inConditional: innermostGroup > 0,
          conditionalGroup: innermostGroup,
        ));
      }
    }

    // Brace balancing. On if/else lines the special-case handling above
    // already consumed the trailing `{` and a leading `}`.
    var opens = '{'.allMatches(line).length;
    var closes = '}'.allMatches(line).length;
    if (ifOpen || elseOpen) {
      opens--;
      if (trimmed.startsWith('}')) {
        closes--;
      }
    }
    for (var i = 0; i < closes && scopes.isNotEmpty; i++) {
      final popped = scopes.removeLast();
      if (popped > 0) {
        lastClosedIfGroup = popped;
      }
    }
    for (var i = 0; i < opens; i++) {
      scopes.add(0);
    }
  }
  return found.toList();
}

/// Keep only the first variant of each if/else conditional group.
///
/// Plugin gradle files commonly declare both variants of a dependency inside
/// an `if/else` switch (e.g. mobile_scanner: bundled
/// `com.google.mlkit:barcode-scanning` vs unbundled
/// `com.google.android.gms:play-services-mlkit-barcode-scanning`). Gradle
/// picks the branch matching its property default; oka cannot evaluate the
/// condition, so the deterministic policy is: **the first variant in the
/// group wins** (gradle's default branch is declared first in the fixtures
/// this repo tracks), later variants of the same group are dropped with a
/// printed notice. Single-member conditional groups are kept as-is.
///
/// [deps] from several gradle files must carry distinct
/// [ParsedGradleDep.conditionalGroup] ids per file (re-map before calling).
List<ParsedGradleDep> dedupeConditionalDeps(
  final List<ParsedGradleDep> deps, {
  final String pluginName = '',
  final void Function(String notice)? onNotice,
}) {
  final kept = <ParsedGradleDep>[];
  final droppedInGroup = <int, List<ParsedGradleDep>>{};
  for (final dep in deps) {
    if (dep.inConditional &&
        kept.any(
          (final k) => k.conditionalGroup == dep.conditionalGroup,
        )) {
      droppedInGroup
          .putIfAbsent(dep.conditionalGroup, () => [])
          .add(dep);
      continue;
    }
    kept.add(dep);
  }
  if (onNotice != null && droppedInGroup.isNotEmpty) {
    final who = pluginName.isEmpty ? '' : '$pluginName: ';
    for (final entry in droppedInGroup.entries) {
      final winner = kept.firstWhere(
        (final k) => k.conditionalGroup == entry.key,
      );
      onNotice(
        'ℹ️  ${who}conditional if/else dependency variants collapsed: '
        'keeping ${winner.coordinate} (gradle default branch); skipping '
        '${entry.value.map((final d) => d.coordinate).join(", ")}',
      );
    }
  }
  return kept;
}

/// Extract custom maven repository URLs from gradle text.
List<String> parseMavenRepositoryUrls(final String gradleSource) {
  final urls = <String>[];
  final re = RegExp(r'''url\s*(?:=\s*)?uri\(?\s*["']([^"']+)["']''');
  final re2 = RegExp(r'''maven\s*\{\s*url\s+["']([^"']+)["']''');
  final re3 = RegExp(r'''url\s+["'](https?://[^"']+)["']''');
  for (final reX in [re, re2, re3]) {
    for (final m in reX.allMatches(gradleSource)) {
      final u = m.group(1)!;
      if (u.startsWith('http') && !urls.contains(u)) {
        urls.add(u);
      }
    }
  }
  return urls;
}
