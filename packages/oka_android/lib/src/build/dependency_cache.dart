/// Facade over [MavenResolver] — the disk cache + AAR payload front-end
/// (ADR-0007). Kept as a separate library so existing import sites
/// (`package:oka_android/src/build/dependency_cache.dart`) keep working; new
/// code should depend on [MavenResolver] from `maven_resolver.dart`.
library;

import 'package:oka_core/oka_core.dart';

import '../maven_resolver.dart';

export '../maven_resolver.dart'
    show
        MavenHost,
        MavenRepoRegistry,
        ResolvedJar,
        extractAarPayload,
        extractClassesJarFromAar,
        extractClassesJarToFile,
        flutterEmbeddingAndroidXDeps,
        googleMavenUrl,
        minimalAarBytes,
        minimalJarBytes,
        parsePomDependencies,
        parsePomImports,
        parsePomManagedVersions,
        parsePomParent,
        parsePomProperties,
        tryExtractClassesJarFromAar;

/// Disk-cache facade delegating resolution to [MavenResolver].
///
/// Memoizes per-build resolution of Maven coordinates and Flutter AndroidX
/// artifacts: identical coordinates requested by many plugins hit the local
/// cache once, and in-flight requests share one future. Steps receive a
/// shared instance via constructors; `--offline` style builds pass
/// `allowNetwork: false`.
///
/// ```dart
/// final cache = DependencyCache(cacheRoot: '${ctx.cacheDir}/maven');
/// final jar = await cache.resolve(
///   MavenCoordinate.parse('androidx.core:core-ktx:1.13.1')!,
/// );
/// ```
class DependencyCache {
  DependencyCache({
    final String? cacheRoot,
    final bool verbose = false,
    final bool allowNetwork = true,
    final List<String> userRepos = const [],
  }) : resolver = MavenResolver(
          cacheRoot: cacheRoot,
          verbose: verbose,
          allowNetwork: allowNetwork,
          userRepos: userRepos,
        );
  final MavenResolver resolver;

  String get cacheRoot => resolver.cacheRoot;
  bool get verbose => resolver.verbose;

  String localPathFor(final MavenCoordinate coord) => resolver.localPathFor(coord);
  String jarPathFor(final MavenCoordinate coord) => resolver.jarPathFor(coord);

  Future<ResolvedJar> resolve(
    final MavenCoordinate coord, {
    final List<int>? fixtureBytes,
    final List<String> extraRepos = const [],
  }) =>
      resolver.resolve(
        coord,
        fixtureBytes: fixtureBytes,
        extraRepos: extraRepos,
      );

  Future<List<ResolvedJar>> resolveFlutterAndroidX({
    final Map<String, List<int>> fixtures = const {},
  }) =>
      resolver.resolveFlutterAndroidX(fixtures: fixtures);

  Future<List<ResolvedJar>> resolveWithTransitives(
    final List<MavenCoordinate> roots, {
    final List<String> extraRepos = const [],
    final int maxDepth = 2,
    final int maxArtifacts = 250,
    final void Function(MavenCoordinate coord, Object error)? onFailure,
  }) =>
      resolver.resolveWithTransitives(
        roots,
        extraRepos: extraRepos,
        maxDepth: maxDepth,
        maxArtifacts: maxArtifacts,
        onFailure: onFailure,
      );
}
