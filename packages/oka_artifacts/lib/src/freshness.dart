import 'dart:convert';
import 'dart:io';

/// Shared artifact freshness (ADR-0043 / 0047): missing artifact, newer
/// package config, newer declared source file, or any watched source root
/// containing newer sources ⇒ stale. One mechanic for every "is this
/// build artifact fresh?" question — build scripts, observe/apply probes,
/// and refresh specs all read the same predicate.
final class ArtifactFreshnessReport {
  const ArtifactFreshnessReport({
    required this.artifactPath,
    required this.fresh,
    required this.reason,
  });

  final String artifactPath;
  final bool fresh;
  final String reason;

  Map<String, Object?> toJson() => {
        'artifactPath': artifactPath,
        'fresh': fresh,
        'reason': reason,
      };
}

/// Returns whether [artifactPath] is at least as new as its declared
/// sources.
///
/// [sourceRoots] are directories scanned recursively for files with
/// matching [extensions]; [sourceFiles] are compared by mtime directly.
/// With [packageConfigPath] set, a newer config is stale by itself, and
/// [scanPackageConfigLibs] additionally scans every `lib/` the config
/// resolves (the honest staleness set for artifacts compiled against the
/// full workspace graph, including path deps outside the checkout).
ArtifactFreshnessReport inspectArtifactFreshness({
  required String artifactPath,
  required List<String> sourceRoots,
  List<String> extensions = const <String>['dart'],
  List<String> sourceFiles = const <String>[],
  String? packageConfigPath,
  bool scanPackageConfigLibs = false,
}) {
  final artifact = File(artifactPath);
  if (!artifact.existsSync()) {
    return ArtifactFreshnessReport(
      artifactPath: artifactPath,
      fresh: false,
      reason: 'missing',
    );
  }
  final artifactMtime = artifact.lastModifiedSync();
  if (packageConfigPath != null) {
    final config = File(packageConfigPath);
    if (config.existsSync() &&
        config.lastModifiedSync().isAfter(artifactMtime)) {
      return ArtifactFreshnessReport(
        artifactPath: artifactPath,
        fresh: false,
        reason: 'package_config_newer',
      );
    }
  }
  for (final source in sourceFiles) {
    final file = File(source);
    if (file.existsSync() && file.lastModifiedSync().isAfter(artifactMtime)) {
      return ArtifactFreshnessReport(
        artifactPath: artifactPath,
        fresh: false,
        reason: 'source_newer:$source',
      );
    }
  }
  final roots = [...sourceRoots];
  if (scanPackageConfigLibs && packageConfigPath != null) {
    roots.addAll(_packageConfigLibs(packageConfigPath));
  }
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    final newer = Process.runSync('find', [
      root,
      if (extensions.isNotEmpty) ...[
        '(',
        for (var i = 0; i < extensions.length; i++) ...[
          if (i > 0) '-o',
          '-name',
          '*.${extensions[i]}',
        ],
        ')',
      ],
      '-newer',
      artifactPath,
      '-print',
      '-quit',
    ]);
    if ((newer.stdout as String).trim().isNotEmpty) {
      return ArtifactFreshnessReport(
        artifactPath: artifactPath,
        fresh: false,
        reason: 'sources_newer:$root',
      );
    }
  }
  return ArtifactFreshnessReport(
    artifactPath: artifactPath,
    fresh: true,
    reason: 'fresh',
  );
}

/// Every existing `lib/` directory the package config resolves. rootUri
/// may be relative to package_config.json (in .dart_tool/); resolving
/// against the config's own directory keeps out-of-checkout path deps in
/// the staleness set. A missing or malformed config yields no roots — a
/// freshness probe reports, it does not throw.
List<String> _packageConfigLibs(String packageConfigPath) {
  final config = File(packageConfigPath);
  if (!config.existsSync()) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(config.readAsStringSync());
  } on Object {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  final configBase = Uri.directory(config.parent.path);
  final libs = <String>[];
  for (final package in decoded['packages'] as List<dynamic>? ?? const []) {
    if (package is! Map<String, dynamic>) continue;
    final raw = package['rootUri'];
    if (raw is! String) continue;
    final packageRoot = configBase.resolve(raw).toFilePath();
    final lib = '$packageRoot${packageRoot.endsWith('/') ? '' : '/'}lib';
    if (Directory(lib).existsSync()) libs.add(lib);
  }
  return libs;
}
