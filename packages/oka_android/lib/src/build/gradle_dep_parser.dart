/// Lightweight extraction of Maven coordinates from plugin Gradle scripts.
///
/// Handles common Groovy/Kotlin DSL patterns without running Gradle:
/// - `implementation 'group:artifact:version'`
/// - `implementation("group:artifact:version")`
/// - `api "group:artifact:version"`
/// - `compileOnly(...)` skipped for runtime packaging

/// A parsed dependency declaration.
class ParsedGradleDep {
  final String groupId;
  final String artifactId;
  final String version;
  final String configuration; // implementation, api, etc.

  const ParsedGradleDep({
    required this.groupId,
    required this.artifactId,
    required this.version,
    this.configuration = 'implementation',
  });

  String get coordinate => '$groupId:$artifactId:$version';

  @override
  String toString() => coordinate;

  @override
  bool operator ==(Object other) =>
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
List<ParsedGradleDep> parseGradleDependencies(String gradleSource) {
  final found = <ParsedGradleDep>{};
  for (final re in _coordPatterns) {
    for (final m in re.allMatches(gradleSource)) {
      final group = m.group(1)!;
      final artifact = m.group(2)!;
      final version = m.group(3)!;
      // Skip project-local and incomplete versions
      if (version.contains('\$') || version == '+' ) continue;
      if (group == 'project') continue;
      found.add(ParsedGradleDep(
        groupId: group,
        artifactId: artifact,
        version: version,
      ));
    }
  }
  return found.toList();
}

/// Extract custom maven repository URLs from gradle text.
List<String> parseMavenRepositoryUrls(String gradleSource) {
  final urls = <String>[];
  final re = RegExp(r'''url\s*(?:=\s*)?uri\(?\s*["']([^"']+)["']''');
  final re2 = RegExp(r'''maven\s*\{\s*url\s+["']([^"']+)["']''');
  final re3 = RegExp(r'''url\s+["'](https?://[^"']+)["']''');
  for (final reX in [re, re2, re3]) {
    for (final m in reX.allMatches(gradleSource)) {
      final u = m.group(1)!;
      if (u.startsWith('http') && !urls.contains(u)) urls.add(u);
    }
  }
  return urls;
}
