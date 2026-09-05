/// Facade over [MavenResolver] — the disk cache + AAR payload front-end
/// (ADR-0007). Kept as a separate library so existing import sites
/// (`package:oka_android/src/build/dependency_cache.dart`) keep working; new
/// code should depend on [MavenResolver] from `maven_resolver.dart`.
library;

import 'package:oka_core/oka_core.dart';

import '../maven_resolver.dart';

export '../maven_resolver.dart'
    show
        ResolvedJar,
        MavenRepoRegistry,
        MavenHost,
        googleMavenUrl,
        flutterEmbeddingAndroidXDeps,
        tryExtractClassesJarFromAar,
        extractClassesJarFromAar,
        extractClassesJarToFile,
        extractAarPayload,
        minimalJarBytes,
        minimalAarBytes,
        parsePomDependencies,
        parsePomParent,
        parsePomManagedVersions,
        parsePomProperties,
        parsePomImports;

/// Disk-cache facade delegating resolution to [MavenResolver].
class DependencyCache {
  final MavenResolver resolver;

  DependencyCache({
    String? cacheRoot,
    bool verbose = false,
    bool allowNetwork = true,
    List<String> userRepos = const [],
  }) : resolver = MavenResolver(
          cacheRoot: cacheRoot,
          verbose: verbose,
          allowNetwork: allowNetwork,
          userRepos: userRepos,
        );

  String get cacheRoot => resolver.cacheRoot;
  bool get verbose => resolver.verbose;

  String localPathFor(MavenCoordinate coord) => resolver.localPathFor(coord);
  String jarPathFor(MavenCoordinate coord) => resolver.jarPathFor(coord);

  Future<ResolvedJar> resolve(
    MavenCoordinate coord, {
    List<int>? fixtureBytes,
    List<String> extraRepos = const [],
  }) =>
      resolver.resolve(
        coord,
        fixtureBytes: fixtureBytes,
        extraRepos: extraRepos,
      );

  Future<List<ResolvedJar>> resolveFlutterAndroidX({
    Map<String, List<int>> fixtures = const {},
  }) =>
      resolver.resolveFlutterAndroidX(fixtures: fixtures);

  Future<List<ResolvedJar>> resolveWithTransitives(
    List<MavenCoordinate> roots, {
    List<String> extraRepos = const [],
    int maxDepth = 2,
    int maxArtifacts = 250,
  }) =>
      resolver.resolveWithTransitives(
        roots,
        extraRepos: extraRepos,
        maxDepth: maxDepth,
        maxArtifacts: maxArtifacts,
      );
}
