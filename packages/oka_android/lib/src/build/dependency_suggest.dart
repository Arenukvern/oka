import 'dart:io';

import 'package:path/path.dart' as p;

/// A suggested Maven coordinate for a missing class.
class DependencySuggestion {
  const DependencySuggestion({
    required this.groupId,
    required this.artifactId,
    required this.version,
    required this.missingClass,
    required this.confidence,
    required this.source,
  });

  final String groupId;
  final String artifactId;
  final String version;
  final String missingClass;

  /// Confidence 0..1.
  final double confidence;

  /// Provenance: 'known-class' | 'cache-scan'.
  final String source;

  String get coordinate => '$groupId:$artifactId:$version';

  /// Ready-to-paste oka.yaml snippet.
  String get yamlSnippet =>
      'pipeline:\n'
      '  extra_deps:\n'
      '    - "$coordinate"';
}

/// Offline knowledge base mapping well-known runtime-missing classes to their
/// Maven artifacts. Keys are class prefixes matched against
/// `NoClassDefFoundError: Lcom/foo/Bar;` descriptors.
///
/// Versions track the set resolved by the default embedding pipeline where
/// applicable; otherwise latest-known-stable.
const Map<
  String,
  List<({String group, String artifact, String version, double confidence})>
>
kKnownClassArtifacts = {
  // AndroidX collection (SimpleArrayMap, SparseArrayCompat, …)
  'androidx.collection': [
    (
      group: 'androidx.collection',
      artifact: 'collection-jvm',
      version: '1.4.4',
      confidence: 0.95,
    ),
    (
      group: 'androidx.collection',
      artifact: 'collection',
      version: '1.4.4',
      confidence: 0.8,
    ),
  ],
  // AndroidX core (WindowInsetsControllerCompat, …)
  'androidx.core': [
    (
      group: 'androidx.core',
      artifact: 'core',
      version: '1.13.1',
      confidence: 0.9,
    ),
  ],
  // AndroidX lifecycle runtime/common
  'androidx.lifecycle': [
    (
      group: 'androidx.lifecycle',
      artifact: 'lifecycle-runtime-android',
      version: '2.8.7',
      confidence: 0.85,
    ),
    (
      group: 'androidx.lifecycle',
      artifact: 'lifecycle-common-jvm',
      version: '2.8.7',
      confidence: 0.85,
    ),
    (
      group: 'androidx.lifecycle',
      artifact: 'lifecycle-viewmodel-android',
      version: '2.8.7',
      confidence: 0.7,
    ),
  ],
  // AndroidX window (WindowMetricsCalculator, …)
  'androidx.window': [
    (
      group: 'androidx.window',
      artifact: 'window',
      version: '1.3.0',
      confidence: 0.95,
    ),
  ],
  // Coroutines (StateFlowKt, CoroutineScope, …)
  'kotlinx.coroutines': [
    (
      group: 'org.jetbrains.kotlinx',
      artifact: 'kotlinx-coroutines-core-jvm',
      version: '1.9.0',
      confidence: 0.95,
    ),
    (
      group: 'org.jetbrains.kotlinx',
      artifact: 'kotlinx-coroutines-android',
      version: '1.9.0',
      confidence: 0.85,
    ),
  ],
  // Kotlin stdlib
  'kotlin.jvm.internal': [
    (
      group: 'org.jetbrains.kotlin',
      artifact: 'kotlin-stdlib',
      version: '2.0.21',
      confidence: 0.9,
    ),
  ],
  'kotlin.text': [
    (
      group: 'org.jetbrains.kotlin',
      artifact: 'kotlin-stdlib',
      version: '2.0.21',
      confidence: 0.9,
    ),
  ],
  // ReLinker (FlutterLoader native lib loading)
  'com.getkeepsafe.relinker': [
    (
      group: 'com.getkeepsafe.relinker',
      artifact: 'relinker',
      version: '1.4.5',
      confidence: 0.98,
    ),
  ],
  // Annotation / experimental
  'androidx.annotation': [
    (
      group: 'androidx.annotation',
      artifact: 'annotation-jvm',
      version: '1.9.1',
      confidence: 0.9,
    ),
    (
      group: 'androidx.annotation',
      artifact: 'annotation-experimental',
      version: '1.4.1',
      confidence: 0.8,
    ),
  ],
  // arch core
  'androidx.arch.core': [
    (
      group: 'androidx.arch.core',
      artifact: 'core-runtime',
      version: '2.2.0',
      confidence: 0.9,
    ),
    (
      group: 'androidx.arch.core',
      artifact: 'core-common',
      version: '2.2.0',
      confidence: 0.9,
    ),
  ],
  // appcompat family commonly pulled by plugins
  'androidx.appcompat': [
    (
      group: 'androidx.appcompat',
      artifact: 'appcompat',
      version: '1.7.0',
      confidence: 0.9,
    ),
  ],
  'androidx.fragment': [
    (
      group: 'androidx.fragment',
      artifact: 'fragment',
      version: '1.8.2',
      confidence: 0.9,
    ),
  ],
  'androidx.activity': [
    (
      group: 'androidx.activity',
      artifact: 'activity',
      version: '1.9.0',
      confidence: 0.9,
    ),
  ],
  // Common plugin deps
  'io.grpc': [
    (
      group: 'io.grpc',
      artifact: 'grpc-core',
      version: '1.65.1',
      confidence: 0.7,
    ),
  ],
  'com.google.protobuf': [
    (
      group: 'com.google.protobuf',
      artifact: 'protobuf-javalite',
      version: '3.25.3',
      confidence: 0.75,
    ),
  ],
  'com.google.gson': [
    (
      group: 'com.google.code.gson',
      artifact: 'gson',
      version: '2.11.0',
      confidence: 0.85,
    ),
  ],
};

/// Extracts the first missing-class descriptor from an ART crash log /
/// NoClassDefFoundError message.
///
/// Handles forms:
/// - `NoClassDefFoundError: Failed resolution of: Lfoo/Bar;`
/// - `NoClassDefFoundError: Lfoo/Bar;`
/// - `ClassNotFoundException: Didn't find class "foo.Bar" on path: …`
String? extractMissingClass(final String logText) {
  final patterns = <RegExp>[
    RegExp(r'Failed resolution of:\s*(L[\w/$]+;)'),
    RegExp(r'NoClassDefFoundError:\s*(L[\w/$]+;)'),
    RegExp(r'Didn.t find class\s*"([\w.$]+)"'),
    RegExp(r'ClassNotFoundException:\s*([\w.$]+)'),
  ];
  for (final re in patterns) {
    final m = re.firstMatch(logText);
    if (m != null) {
      final raw = m.group(1)!;
      return _descriptorToClassName(raw);
    }
  }
  return null;
}

String _descriptorToClassName(final String raw) {
  var s = raw.trim();
  if (s.startsWith('L') && s.endsWith(';')) {
    s = s.substring(1, s.length - 1);
  }
  return s.replaceAll('/', '.');
}

/// Maps a missing class to dependency suggestions.
class MissingDependencyResolver {

  MissingDependencyResolver({final String? cacheRoot})
    : cacheRoot =
          cacheRoot ??
          p.join(Platform.environment['HOME'] ?? '.', '.oka', 'cache', 'maven');
  final String cacheRoot;

  /// Suggest dependencies for [missingClass] (e.g. `androidx.collection.SimpleArrayMap`).
  ///
  /// Strategy:
  /// 1. Known-class table lookup on the full class name and its package
  ///    prefixes (longest match wins).
  /// 2. Cache scan: search cached jars under [cacheRoot] whose path matches
  ///    the package segments of the missing class.
  Future<List<DependencySuggestion>> suggest(final String missingClass) async {
    final results = <DependencySuggestion>[];

    // 1. Longest-prefix known-class match.
    final parts = missingClass.split('.');
    for (var take = parts.length - 1; take >= 1; take--) {
      final prefix = parts.sublist(0, take).join('.');
      final candidates = kKnownClassArtifacts[prefix];
      if (candidates != null) {
        for (final c in candidates) {
          results.add(
            DependencySuggestion(
              groupId: c.group,
              artifactId: c.artifact,
              version: c.version,
              missingClass: missingClass,
              confidence: c.confidence,
              source: 'known-class',
            ),
          );
        }
        break; // longest prefix wins
      }
    }

    // 2. Cache-scan fallback: package path segments vs cached artifact paths.
    if (results.isEmpty && parts.length >= 2) {
      final pkgPath = parts.sublist(0, parts.length - 1).join('/');
      final hits = await _scanCache(pkgPath);
      hits.forEach(results.add);
    }

    // Highest confidence first.
    results.sort((final a, final b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  Future<List<DependencySuggestion>> _scanCache(final String pkgPath) async {
    final out = <DependencySuggestion>[];
    final root = Directory(cacheRoot);
    if (!await root.exists()) return out;

    // Heuristic: walk group dirs matching the package prefix and propose the
    // highest cached version of each candidate artifact.
    await for (final groupDir in root.list()) {
      if (groupDir is! Directory) continue;
      final rel = p.relative(groupDir.path, from: root.path);
      if (!pkgPath.startsWith(rel.replaceAll('/', '.'))) continue;
      await for (final artifactDir in groupDir.list()) {
        if (artifactDir is! Directory) continue;
        final versions = <String>[];
        await for (final v in artifactDir.list()) {
          if (v is Directory) versions.add(p.basename(v.path));
        }
        if (versions.isEmpty) continue;
        versions.sort((final a, final b) {
          final pa = a.split('.').map(int.tryParse).toList();
          final pb = b.split('.').map(int.tryParse).toList();
          for (
            var i = 0;
            i < (pa.length > pb.length ? pa.length : pb.length);
            i++
          ) {
            final x = i < pa.length ? (pa[i] ?? 0) : 0;
            final y = i < pb.length ? (pb[i] ?? 0) : 0;
            if (x != y) return x.compareTo(y);
          }
          return 0;
        });
        final latest = versions.last;
        out.add(
          DependencySuggestion(
            groupId: rel.replaceAll('/', '.'),
            artifactId: p.basename(artifactDir.path),
            version: latest,
            missingClass: pkgPath,
            confidence: 0.5,
            source: 'cache-scan',
          ),
        );
      }
    }
    return out;
  }
}

/// Formats suggestions into user-facing guidance with copy-pasteable fixes.
String formatSuggestions(
  final String missingClass,
  final List<DependencySuggestion> suggestions,
) {
  if (suggestions.isEmpty) {
    return 'No known Maven artifact found for "$missingClass".\n'
        'Search https://maven.google.com or https://central.sonatype.com for '
        'the class, then add it to oka.yaml:\n\n'
        'pipeline:\n'
        '  extra_deps:\n'
        '    - "group:artifact:version"';
  }
  final buf = StringBuffer()
    ..writeln('💡 Missing class "$missingClass" maps to:')
    ..writeln();
  for (var i = 0; i < suggestions.length && i < 3; i++) {
    final s = suggestions[i];
    buf.writeln(
      '   ${i + 1}. ${s.coordinate}  (${s.source}, confidence ${(s.confidence * 100).toStringAsFixed(0)}%)',
    );
  }
  buf
    ..writeln()
    ..writeln('Fix — add to oka.yaml and rebuild:')
    ..writeln()
    ..writeln(suggestions.first.yamlSnippet)
    ..writeln()
    ..writeln('Or run: oka get dep ${suggestions.first.coordinate}');
  return buf.toString();
}
