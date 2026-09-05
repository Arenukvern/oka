import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// A Maven coordinate for Android dependencies.
/// Minimal fixed set required for Flutter embedding hosts (no plugins).
///
/// Prefer JVM/Android artifacts that actually ship `classes.jar` — some
/// AndroidX "runtime" AARs are empty metadata shells (e.g. lifecycle-runtime).
List<MavenCoordinate> flutterEmbeddingAndroidXDeps() {
  return const [
    MavenCoordinate(
      groupId: 'androidx.annotation',
      artifactId: 'annotation-jvm',
      version: '1.9.1',
      packaging: 'jar',
    ),
    MavenCoordinate(
      groupId: 'androidx.lifecycle',
      artifactId: 'lifecycle-common-jvm',
      version: '2.8.7',
      packaging: 'jar',
    ),
    MavenCoordinate(
      groupId: 'androidx.lifecycle',
      artifactId: 'lifecycle-runtime-android',
      version: '2.8.7',
      packaging: 'aar',
    ),
    MavenCoordinate(
      groupId: 'androidx.arch.core',
      artifactId: 'core-common',
      version: '2.2.0',
      packaging: 'jar',
    ),
    MavenCoordinate(
      groupId: 'androidx.arch.core',
      artifactId: 'core-runtime',
      version: '2.2.0',
      packaging: 'aar',
    ),
    MavenCoordinate(
      groupId: 'androidx.core',
      artifactId: 'core',
      version: '1.13.1',
      packaging: 'aar',
    ),
    // androidx.core's hard runtime dependency (WindowInsetsControllerCompat
    // and friends use SimpleArrayMap / SparseArrayCompat).
    MavenCoordinate(
      groupId: 'androidx.collection',
      artifactId: 'collection-jvm',
      version: '1.4.4',
      packaging: 'jar',
    ),
    MavenCoordinate(
      groupId: 'androidx.annotation',
      artifactId: 'annotation-experimental',
      version: '1.4.1',
      packaging: 'aar',
    ),
    MavenCoordinate(
      groupId: 'androidx.versionedparcelable',
      artifactId: 'versionedparcelable',
      version: '1.1.1',
      packaging: 'aar',
    ),
    MavenCoordinate(
      groupId: 'androidx.tracing',
      artifactId: 'tracing',
      version: '1.2.0',
      packaging: 'aar',
    ),
    // Kotlin annotations referenced by Flutter embedding / AndroidX metadata
    MavenCoordinate(
      groupId: 'org.jetbrains.kotlin',
      artifactId: 'kotlin-stdlib',
      version: '2.0.21',
      packaging: 'jar',
    ),
    // Hard runtime dependency of androidx.lifecycle 2.8+
    // (LifecycleRegistry uses kotlinx.coroutines.flow.StateFlow).
    MavenCoordinate(
      groupId: 'org.jetbrains.kotlinx',
      artifactId: 'kotlinx-coroutines-core-jvm',
      version: '1.9.0',
      packaging: 'jar',
    ),
    // Used by FlutterLoader to load libflutter.so robustly on old devices.
    MavenCoordinate(
      groupId: 'com.getkeepsafe.relinker',
      artifactId: 'relinker',
      version: '1.4.5',
      packaging: 'aar',
    ),
    // Flutter's ViewUtils uses WindowMetricsCalculator for display metrics.
    MavenCoordinate(
      groupId: 'androidx.window',
      artifactId: 'window',
      version: '1.3.0',
      packaging: 'aar',
    ),
  ];
}

/// Declarative Maven repository routing (ADR-0007): one authoritative
/// group-prefix → host map instead of scattered hardcoded prefix checks.
class MavenRepoRegistry {
  /// Group prefixes hosted on Google Maven (dl.google.com/dl/android/maven2).
  static const googleHosted = <String>[
    'androidx.',
    'com.android.',
    'com.google.android.',
    'com.google.mlkit',
    'com.google.firebase',
    'com.google.gms',
    'com.google.dagger',
    'com.google.testing.platform',
  ];

  /// Group prefixes hosted on Maven Central.
  static const centralHosted = <String>[
    'org.jetbrains',
    'com.squareup',
    'org.slf4j',
    'javax.',
    'org.apache.',
    'commons-',
    'io.grpc',
    'com.google.guava',
    'com.google.code',
    'com.fasterxml',
    'org.checkerframework',
    'org.osgi',
    'net.sf',
    'org.ow2.asm',
  ];

  /// Group prefixes available only on vendor repositories (routing hint:
  /// user repos are tried first).
  static const vendorOnly = <String>['ru.rustore', 'ru.vk'];

  static final MavenRepoRegistry instance = MavenRepoRegistry();

  final List<({String prefix, MavenHost host})> _routes;

  MavenRepoRegistry({List<({String prefix, MavenHost host})>? routes})
      : _routes = routes ?? _defaultRoutes();

  static List<({String prefix, MavenHost host})> _defaultRoutes() => [
        for (final g in googleHosted) (prefix: g, host: MavenHost.google),
        for (final g in vendorOnly) (prefix: g, host: MavenHost.vendor),
        for (final g in centralHosted) (prefix: g, host: MavenHost.central),
      ];

  MavenHost hostFor(String groupId) {
    for (final r in _routes) {
      if (groupId.startsWith(r.prefix)) return r.host;
    }
    return MavenHost.unknown;
  }

  /// Ordered candidate URLs: primary host first, then the alternative
  /// store, then user repositories (vendor-only groups try user repos
  /// first). Deduplicated.
  List<String> candidatesFor(
    MavenCoordinate c, {
    List<String> userRepos = const [],
  }) {
    final urls = <String>[];
    void add(String u) {
      if (!urls.contains(u)) urls.add(u);
    }

    String url(MavenHost host) => switch (host) {
          MavenHost.google =>
            'https://dl.google.com/dl/android/maven2/${c.pathSegment}/${c.fileName}',
          MavenHost.central =>
            'https://repo1.maven.org/maven2/${c.pathSegment}/${c.fileName}',
          _ => '',
        };

    final host = hostFor(c.groupId);
    final userUrls = [
      for (final base in userRepos)
        '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}'
            '/${c.pathSegment}/${c.fileName}',
    ];

    // Vendor-only groups: user repos first (they host the artifacts).
    if (host == MavenHost.vendor) {
      for (final u in userUrls) {
        add(u);
      }
    }
    add(url(MavenHost.google));
    add(url(MavenHost.central));
    if (host != MavenHost.vendor) {
      for (final u in userUrls) {
        add(u);
      }
    }
    return urls.where((u) => u.isNotEmpty).toList();
  }
}

enum MavenHost { google, central, vendor, unknown }

/// Builds a Maven URL for [coord] via the default [MavenRepoRegistry].
String googleMavenUrl(MavenCoordinate coord) =>
    MavenRepoRegistry.instance.candidatesFor(coord).first;

/// Extracts `classes.jar` bytes from an AAR (zip) archive.
///
/// Returns null when the AAR is a metadata-only shell (no classes.jar).
Uint8List? tryExtractClassesJarFromAar(List<int> aarBytes) {
  final archive = ZipDecoder().decodeBytes(aarBytes);
  for (final file in archive) {
    if (file.isFile &&
        (file.name == 'classes.jar' || file.name.endsWith('/classes.jar'))) {
      return Uint8List.fromList(file.content as List<int>);
    }
  }
  return null;
}

/// Extracts `classes.jar` bytes from an AAR (zip) archive.
Uint8List extractClassesJarFromAar(List<int> aarBytes) {
  final jar = tryExtractClassesJarFromAar(aarBytes);
  if (jar != null) return jar;
  throw Exception('classes.jar not found in AAR');
}

/// Writes extracted classes.jar to [destJarPath]; returns path.
Future<String> extractClassesJarToFile(
  List<int> aarBytes,
  String destJarPath,
) async {
  final jarBytes = extractClassesJarFromAar(aarBytes);
  await File(destJarPath).parent.create(recursive: true);
  await File(destJarPath).writeAsBytes(jarBytes, flush: true);
  return destJarPath;
}

/// Result of resolving one coordinate to a local JAR path.
class ResolvedJar {
  final MavenCoordinate coordinate;
  final String jarPath;

  /// Native libs extracted from an AAR: abi → .so paths (empty for jars).
  final Map<String, List<String>> nativeLibsByAbi;

  /// Resource dirs extracted from an AAR (values XML etc.), empty for jars.
  final List<String> resDirs;

  const ResolvedJar({
    required this.coordinate,
    required this.jarPath,
    this.nativeLibsByAbi = const {},
    this.resDirs = const [],
  });
}

/// Extracts AAR payload beyond classes.jar: jni/<abi>/*.so natives and res/.
///
/// Extraction target layout under [destDir]:
/// - `jni/<abi>/<name>.so`
/// - `res/<original res tree>`
/// Returns what was found; callers merge into staging/res compile inputs.
Future<({Map<String, List<String>> nativeLibsByAbi, List<String> resDirs})>
extractAarPayload(
  List<int> aarBytes,
  String destDir, {
  bool verbose = false,
}) async {
  final archive = ZipDecoder().decodeBytes(aarBytes);
  final natives = <String, List<String>>{};
  var hasRes = false;

  for (final file in archive) {
    if (!file.isFile) continue;
    final name = file.name.replaceAll('\\', '/');

    // jni/<abi>/lib*.so
    final jniMatch = RegExp(
      '^jni/([^/]+)/(lib[^/]+[.]so)' + r'$',
    ).firstMatch(name);
    if (jniMatch != null) {
      final abi = jniMatch.group(1)!;
      final out = p.join(destDir, name);
      await File(out).parent.create(recursive: true);
      await File(out).writeAsBytes(
        Uint8List.fromList(file.content as List<int>),
        flush: true,
      );
      natives.putIfAbsent(abi, () => []).add(out);
      continue;
    }

    // res/** — only values XML is aapt2-compile-ready as-is; copy the tree.
    if (name.startsWith('res/') && name.endsWith('.xml')) {
      hasRes = true;
      final out = p.join(destDir, name);
      await File(out).parent.create(recursive: true);
      await File(out).writeAsBytes(
        Uint8List.fromList(file.content as List<int>),
        flush: true,
      );
    }
  }

  final resDirs = hasRes ? [p.join(destDir, 'res')] : const <String>[];
  if (verbose && (natives.isNotEmpty || resDirs.isNotEmpty)) {
    final n = natives.values.fold<int>(0, (a, b) => a + b.length);
    print('   AAR payload: $n natives, ${resDirs.length} res dir(s)');
  }
  return (nativeLibsByAbi: natives, resDirs: resDirs);
}

/// Resolves Maven coordinates to local jars (ADR-0007): repo routing,
/// download with packaging fallback, AAR payload extraction, POM-graph
/// transitive resolution (parents, BOMs, properties), memoization and
/// parallel BFS.
class MavenResolver {
  final String cacheRoot;
  final bool verbose;
  final http.Client? httpClient;

  /// Per-run memoization: coordinate -> resolved result. Shared across all
  /// plugins in one build so duplicate roots (kotlin-stdlib, androidx core…)
  /// resolve once. In-flight futures de-duplicate concurrent resolutions.
  final Map<String, ResolvedJar> _memo = {};
  final Map<String, Future<ResolvedJar>> _inflight = {};
  final bool allowNetwork;

  /// User-declared repositories tried before/after built-in routing.
  final List<String> userRepos;

  MavenResolver({
    String? cacheRoot,
    this.verbose = false,
    this.httpClient,
    this.allowNetwork = true,
    this.userRepos = const [],
  }) : cacheRoot =
           cacheRoot ??
           p.join(
             Platform.environment['HOME'] ??
                 Platform.environment['USERPROFILE'] ??
                 '.',
             '.oka',
             'cache',
             'maven',
           );

  String localPathFor(MavenCoordinate coord) {
    return p.join(
      cacheRoot,
      coord.groupId.replaceAll('.', '/'),
      coord.artifactId,
      coord.version,
      coord.fileName,
    );
  }

  String jarPathFor(MavenCoordinate coord) {
    if (coord.packaging == 'jar') {
      return localPathFor(coord);
    }
    // AAR → extracted classes jar next to it
    return p.join(
      cacheRoot,
      coord.groupId.replaceAll('.', '/'),
      coord.artifactId,
      coord.version,
      '${coord.artifactId}-${coord.version}-classes.jar',
    );
  }

  /// Resolve [coord] to a local JAR (downloads if allowed and missing).
  ///
  /// [extraRepos] are tried before Google Maven / Maven Central.
  /// If packaging is aar and download 404s, retries as jar.
  Future<ResolvedJar> resolve(
    MavenCoordinate coord, {
    List<int>? fixtureBytes,
    List<String> extraRepos = const [],
  }) {
    // Memoize per DependencyCache instance (per build): identical coordinates
    // requested by many plugins resolve once; concurrent requests share one
    // in-flight future.
    final memoKey = coord.cacheKey;
    final hit = _memo[memoKey];
    if (hit != null) return Future.value(hit);
    final existing = _inflight[memoKey];
    if (existing != null) return existing;
    final fut = _resolveUncached(coord, fixtureBytes, extraRepos);
    _inflight[memoKey] = fut;
    return fut.then((r) {
      _memo[memoKey] = r;
      return r;
    }).whenComplete(() {
      _inflight.remove(memoKey);
    });
  }

  Future<ResolvedJar> _resolveUncached(
    MavenCoordinate coord,
    List<int>? fixtureBytes,
    List<String> extraRepos,
  ) async {
    var working = coord;
    final jarPath = jarPathFor(working);
    if (await File(jarPath).exists()) {
      final existingLen = await File(jarPath).length();
      // Do not treat metadata-only empty shells as a successful cache hit.
      if (existingLen > 200) {
        return ResolvedJar(coordinate: working, jarPath: jarPath);
      }
      try {
        await File(jarPath).delete();
      } catch (_) {}
    }

    List<int> bytes;
    if (fixtureBytes != null) {
      bytes = fixtureBytes;
    } else if (!allowNetwork) {
      throw Exception(
        'Dependency not in cache and network disabled: $coord\n'
        'Expected at: $jarPath',
      );
    } else {
      try {
        final downloaded = await _downloadArtifact(
          working,
          extraRepos: extraRepos,
        );
        bytes = downloaded.bytes;
        working = downloaded.coord;
      } on Exception {
        // Packaging guess fallback: gradle parsers default to `jar`, but many
        // artifacts (ML Kit, Play services, AndroidX UI libs) ship only as
        // AARs — and metadata-only POMs sometimes exist only as `pom`+jar.
        final alt = working.packaging == 'jar' ? 'aar' : 'jar';
        if (verbose) {
          print('   ↳ $working@${
          working.packaging} 404 — retrying as $alt');
        }
        final retried = await _downloadArtifact(
          MavenCoordinate(
            groupId: working.groupId,
            artifactId: working.artifactId,
            version: working.version,
            packaging: alt,
          ),
          extraRepos: extraRepos,
        );
        bytes = retried.bytes;
        working = retried.coord;
      }
    }

    final artifactPath = localPathFor(working);
    await File(artifactPath).parent.create(recursive: true);
    await File(artifactPath).writeAsBytes(bytes, flush: true);

    final outJar = jarPathFor(working);
    if (working.packaging == 'aar') {
      final classes = tryExtractClassesJarFromAar(bytes);
      if (classes == null) {
        if (verbose) {
          print(
            '⚠️  $working has no classes.jar (metadata AAR); using empty jar',
          );
        }
        await File(outJar).parent.create(recursive: true);
        await File(outJar).writeAsBytes(minimalJarBytes(), flush: true);
      } else {
        await File(outJar).parent.create(recursive: true);
        await File(outJar).writeAsBytes(classes, flush: true);
      }

      // Extract natives + res alongside the classes jar (ADR: AAR processing).
      final payloadDir = p.join(
        cacheRoot,
        working.groupId.replaceAll('.', '/'),
        working.artifactId,
        working.version,
        'payload',
      );
      final payload = await extractAarPayload(
        bytes,
        payloadDir,
        verbose: verbose,
      );
      return ResolvedJar(
        coordinate: working,
        jarPath: outJar,
        nativeLibsByAbi: payload.nativeLibsByAbi,
        resDirs: payload.resDirs,
      );
    }

    return ResolvedJar(coordinate: working, jarPath: outJar);
  }

  Future<({MavenCoordinate coord, List<int> bytes})> _downloadArtifact(
    MavenCoordinate coord, {
    List<String> extraRepos = const [],
  }) async {
    final candidates = <MavenCoordinate>[coord];
    // AndroidX multiplatform: real classes often live in *-android / *-jvm
    if (coord.groupId.startsWith('androidx.') &&
        !coord.artifactId.endsWith('-android') &&
        !coord.artifactId.endsWith('-jvm')) {
      candidates.add(
        MavenCoordinate(
          groupId: coord.groupId,
          artifactId: '${coord.artifactId}-android',
          version: coord.version,
          packaging: 'aar',
        ),
      );
      candidates.add(
        MavenCoordinate(
          groupId: coord.groupId,
          artifactId: '${coord.artifactId}-jvm',
          version: coord.version,
          packaging: 'jar',
        ),
      );
    }
    if (coord.packaging == 'aar') {
      candidates.add(
        MavenCoordinate(
          groupId: coord.groupId,
          artifactId: coord.artifactId,
          version: coord.version,
          packaging: 'jar',
        ),
      );
    } else if (coord.packaging == 'jar') {
      candidates.add(
        MavenCoordinate(
          groupId: coord.groupId,
          artifactId: coord.artifactId,
          version: coord.version,
          packaging: 'aar',
        ),
      );
    }

    final client = httpClient ?? http.Client();
    try {
      for (final c in candidates) {
        for (final url in _candidateUrls(c, extraRepos)) {
          if (verbose) {
            print('📥 Trying $c\n   $url');
          }
          try {
            final response = await client
                .get(
                  Uri.parse(url),
                  // Explicit identity encoding: some artifactory hosts
                  // (e.g. vkpartner nexus) hang their gzip response stream,
                  // which stalls the build indefinitely. Jars/AARs are zip
                  // containers — transport compression gains nothing.
                  headers: const {
                    'Accept-Encoding': 'identity',
                    'User-Agent': 'oka build tool',
                  },
                )
                .timeout(const Duration(seconds: 60));
            if (response.statusCode == 200 && response.bodyBytes.length > 32) {
              return (coord: c, bytes: response.bodyBytes);
            }
            if (verbose) {
              print('   ↳ HTTP ${response.statusCode} from $url');
            }
          } catch (e) {
            if (verbose) print('   ↳ failed: $e');
            // try next URL
          }
        }
      }
      throw Exception('Failed to download $coord from known repositories');
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  /// Candidate URLs for [c]: built-in routing + user repositories.
  List<String> _candidateUrls(MavenCoordinate c, List<String> extraRepos) =>
      MavenRepoRegistry.instance.candidatesFor(
        c,
        userRepos: [...userRepos, ...extraRepos],
      );

  /// Resolve the fixed Flutter embedding AndroidX set.
  Future<List<ResolvedJar>> resolveFlutterAndroidX({
    Map<String, List<int>> fixtures = const {},
  }) async {
    final results = <ResolvedJar>[];
    for (final coord in flutterEmbeddingAndroidXDeps()) {
      results.add(await resolve(coord, fixtureBytes: fixtures[coord.cacheKey]));
    }
    return results;
  }

  /// Resolve [roots] plus limited POM transitive compile dependencies.
  Future<List<ResolvedJar>> resolveWithTransitives(
    List<MavenCoordinate> roots, {
    List<String> extraRepos = const [],
    int maxDepth = 3,
    int maxArtifacts = 250,
  }) async {
    final seen = <String>{};
    final out = <ResolvedJar>[];
    final queue = <({MavenCoordinate c, int depth})>[
      for (final r in roots) (c: r, depth: 0),
    ];
    var iterations = 0;
    const maxIterations = 800;

    // Level-synchronized BFS: resolve the current level in parallel (network
    // round-trips dominate cold builds), then expand the next level.
    while (queue.isNotEmpty &&
        out.length < maxArtifacts &&
        iterations < maxIterations) {
      // Take the whole current level (up to remaining budget).
      final budget = maxArtifacts - out.length;
      final level = <({MavenCoordinate c, int depth})>[];
      while (queue.isNotEmpty && level.length < budget) {
        final item = queue.removeAt(0);
        iterations++;
        if (!seen.add(item.c.cacheKey)) continue;
        level.add(item);
      }
      if (level.isEmpty) break;

      final expansions = await Future.wait(
        level.map((item) => _resolveAndExpand(item, queue, seen, extraRepos, maxDepth)),
      );
      for (final e in expansions) {
        if (e.resolved != null && e.length > 200) {
          out.add(e.resolved!);
        } else if (e.resolved != null && verbose) {
          print('   skip empty jar ${e.resolved!.coordinate}');
        }
        queue.addAll(e.next);
      }
    }
    if (verbose) {
      print(
        '   resolveWithTransitives: ${out.length} jars '
        '($iterations iterations)',
      );
    }
    return out;
  }

  /// Resolves one coordinate and computes its BFS expansion. Failures are
  /// isolated per artifact — one bad download never empties a plugin's
  /// classpath.
  Future<({ResolvedJar? resolved, int length, List<({MavenCoordinate c, int depth})> next})>
  _resolveAndExpand(
    ({MavenCoordinate c, int depth}) item,
    List<({MavenCoordinate c, int depth})> queue,
    Set<String> seen,
    List<String> extraRepos,
    int maxDepth,
  ) async {
    try {
      final resolved = await resolve(item.c, extraRepos: extraRepos);
      final len = await File(resolved.jarPath).length();
      final next = <({MavenCoordinate c, int depth})>[];

      // Prefer android/jvm variants when metadata-only (do not expand -ktx)
      if (len <= 200) {
        final base = item.c.artifactId.replaceAll(
          RegExp(r'-(android|jvm|ktx)$'),
          '',
        );
        for (final alt in [
          MavenCoordinate(
            groupId: item.c.groupId,
            artifactId: '$base-android',
            version: item.c.version,
            packaging: 'aar',
          ),
          MavenCoordinate(
            groupId: item.c.groupId,
            artifactId: '$base-jvm',
            version: item.c.version,
            packaging: 'jar',
          ),
        ]) {
          if (!seen.contains(alt.cacheKey) &&
              alt.artifactId != item.c.artifactId) {
            next.add((c: alt, depth: item.depth));
          }
        }
      }

      if (item.depth < maxDepth) {
        final pomDeps = await _fetchPomDependencies(
          resolved.coordinate,
          extraRepos: extraRepos,
        );
        for (final d in pomDeps) {
          // Skip massive optional graphs
          if (d.groupId.startsWith('org.jetbrains.kotlin') &&
              d.artifactId.contains('stdlib-common')) {
            continue;
          }
          if (!seen.contains(d.cacheKey)) {
            next.add((c: d, depth: item.depth + 1));
          }
        }
      }
      return (resolved: resolved, length: len, next: next);
    } catch (e) {
      if (verbose) print('   resolve skip ${item.c}: $e');
      return (resolved: null, length: 0, next: const <({MavenCoordinate c, int depth})>[]);
    }
  }

  Future<List<MavenCoordinate>> _fetchPomDependencies(
    MavenCoordinate coord, {
    List<String> extraRepos = const [],
  }) async {
    if (!allowNetwork) return const [];
    final pomCoord = MavenCoordinate(
      groupId: coord.groupId,
      artifactId: coord.artifactId,
      version: coord.version,
      packaging: 'pom',
    );
    // localPathFor uses packaging for filename — pom file
    final pomPath = localPathFor(pomCoord);
    List<int> bytes;
    if (await File(pomPath).exists()) {
      bytes = await File(pomPath).readAsBytes();
    } else {
      try {
        final dl = await _downloadArtifact(pomCoord, extraRepos: extraRepos);
        bytes = dl.bytes;
        await File(pomPath).parent.create(recursive: true);
        await File(pomPath).writeAsBytes(bytes);
      } catch (_) {
        return const [];
      }
    }
    final pomXml = String.fromCharCodes(bytes);
    final deps = parsePomDependencies(pomXml);

    // Version-less <dependency> entries (versions managed by a parent POM's
    // <dependencyManagement> or <properties>): fetch the parent once and
    // resolve versions from it.
    final needsVersion = deps.any((d) => d.version.isEmpty);
    if (!needsVersion) return deps;

    final parent = parsePomParent(pomXml);
    if (parent == null) return deps;
    final parentXml = await _pomXml(parent, extraRepos);
    if (parentXml == null) return deps;

    // Walk the parent chain (bounded): grandparents may hold versions for
    // entries the direct parent leaves to BOM imports or deeper inheritance.
    final managed = <String, String>{...parsePomManagedVersions(parentXml)};
    final ownProps = parsePomProperties(pomXml);
    final parentProps = parsePomProperties(parentXml);
    // BOM imports of the direct parent: slf4j-bom etc. merge their managed
    // versions (resolving ${} refs against the parent's properties first).
    final importsQueue = parsePomImports(parentXml)
        .map((c) => MavenCoordinate(
              groupId: c.groupId,
              artifactId: c.artifactId,
              version: c.version.startsWith(r'${')
                  ? (parsePomProperties(parentXml)[
                          c.version.substring(2, c.version.length - 1)] ??
                      '')
                  : c.version,
              packaging: 'pom',
            ))
        .where((c) => c.version.isNotEmpty)
        .toList();
    if (verbose) {
      print(
        '   parent-managed: ${managed.length} entries; '
        'imports: ${importsQueue.map((c) => c.toString()).join(', ')}',
      );
    }
    var bomGuard = 0;
    while (importsQueue.isNotEmpty && bomGuard < 24) {
      bomGuard++;
      final bom = importsQueue.removeAt(0);
      if (verbose) print('   BOM import: $bom');
      final bomXml = await _pomXml(bom, extraRepos);
      if (verbose && bomXml == null) print('   BOM fetch failed: $bom');
      if (bomXml == null) continue;
      final props = parsePomProperties(bomXml);
      parsePomManagedVersions(bomXml).forEach((k, v) {
        managed[k] = v.startsWith(r'${')
            ? (v == r'${project.version}'
                ? bom.version
                : props[v.substring(2, v.length - 1)] ?? v)
            : v;
      });
      // Nested BOM imports (rare) — bounded.
      for (final nested in parsePomImports(bomXml)) {
        if (importsQueue.length < 24) importsQueue.add(nested);
      }
    }

    var grandparent = parsePomParent(parentXml);
    var levels = 0;
    while (grandparent != null && levels < 3) {
      levels++;
      final gpXml = await _pomXml(grandparent, extraRepos);
      if (gpXml == null) break;
      managed.addAll(parsePomManagedVersions(gpXml));
      parentProps.addAll(parsePomProperties(gpXml));
      grandparent = parsePomParent(gpXml);
    }
    String resolveVersion(String v) {
      if (v.startsWith(r'${') && v.endsWith('}')) {
        final key = v.substring(2, v.length - 1);
        return ownProps[key] ?? parentProps[key] ?? '';
      }
      return v;
    }

    return deps.map((d) {
      var v = d.version;
      if (v.isEmpty) {
        v = managed['${d.groupId}:${d.artifactId}'] ?? '';
      }
      v = resolveVersion(v);
      return MavenCoordinate(groupId: d.groupId, artifactId: d.artifactId, version: v);
    }).where((d) => d.version.isNotEmpty && !d.version.contains(r'${')).toList();
  }

  /// Downloads (or reads cached) POM XML for [coord]; null when unavailable.
  Future<String?> _pomXml(
    MavenCoordinate coord,
    List<String> extraRepos,
  ) async {
    final pomCoord = MavenCoordinate(
      groupId: coord.groupId,
      artifactId: coord.artifactId,
      version: coord.version,
      packaging: 'pom',
    );
    final pomPath = localPathFor(pomCoord);
    if (await File(pomPath).exists()) return await File(pomPath).readAsString();
    try {
      final dl = await _downloadArtifact(pomCoord, extraRepos: extraRepos);
      await File(pomPath).parent.create(recursive: true);
      await File(pomPath).writeAsBytes(dl.bytes, flush: true);
      return String.fromCharCodes(dl.bytes);
    } catch (e) {
      if (verbose) print('   pom fetch failed for $coord: $e');
      return null;
    }
  }
}

/// Extracts `<parent>` coordinates from a POM, when present.
MavenCoordinate? parsePomParent(String pomXml) {
  final m = RegExp(
    r'<parent>\s*<groupId>([^<]+)</groupId>\s*<artifactId>([^<]+)</artifactId>\s*<version>([^<]+)</version>',
  ).firstMatch(pomXml);
  if (m == null) return null;
  return MavenCoordinate(
    groupId: m.group(1)!,
    artifactId: m.group(2)!,
    version: m.group(3)!,
  );
}

/// Extracts `<dependencyManagement><dependencies>` versions from a POM:
/// map of `groupId:artifactId` → version.
Map<String, String> parsePomManagedVersions(String pomXml) {
  final out = <String, String>{};
  final mgmt = RegExp(
    r'<dependencyManagement>([\s\S]*?)</dependencyManagement>',
  ).firstMatch(pomXml);
  if (mgmt == null) return out;
  for (final block
      in RegExp(r'<dependency>([\s\S]*?)</dependency>')
          .allMatches(mgmt.group(1)!)) {
    final body = block.group(1)!;
    final g = RegExp(r'<groupId>([^<]+)</groupId>').firstMatch(body)?.group(1);
    final a =
        RegExp(r'<artifactId>([^<]+)</artifactId>').firstMatch(body)?.group(1);
    final v = RegExp(r'<version>([^<]+)</version>').firstMatch(body)?.group(1);
    if (g != null && a != null && v != null) out['$g:$a'] = v;
  }
  return out;
}

/// Extracts BOM imports (`<type>pom</type><scope>import</scope>`) from a
/// POM's dependencyManagement — their managed versions merge transitively.
List<MavenCoordinate> parsePomImports(String pomXml) {
  final out = <MavenCoordinate>[];
  final mgmt = RegExp(
    r'<dependencyManagement>([\s\S]*?)</dependencyManagement>',
  ).firstMatch(pomXml);
  if (mgmt == null) return out;
  for (final block
      in RegExp(r'<dependency>([\s\S]*?)</dependency>')
          .allMatches(mgmt.group(1)!)) {
    final body = block.group(1)!;
    if (!RegExp(r'<scope>\s*import\s*</scope>').hasMatch(body)) continue;
    if (!RegExp(r'<type>\s*pom\s*</type>').hasMatch(body)) continue;
    final g = RegExp(r'<groupId>([^<]+)</groupId>').firstMatch(body)?.group(1);
    final a =
        RegExp(r'<artifactId>([^<]+)</artifactId>').firstMatch(body)?.group(1);
    final v = RegExp(r'<version>([^<]+)</version>').firstMatch(body)?.group(1);
    if (g != null && a != null && v != null) {
      out.add(
        MavenCoordinate(groupId: g, artifactId: a, version: v, packaging: 'pom'),
      );
    }
  }
  return out;
}

/// Extracts `<properties>` from a POM: map of property name → value.
Map<String, String> parsePomProperties(String pomXml) {
  final section = RegExp(r'<properties>([\s\S]*?)</properties>')
      .firstMatch(pomXml)
      ?.group(1);
  if (section == null) return const {};
  final out = <String, String>{};
  for (final m
      in RegExp(r'<([a-zA-Z0-9._\-]+)>([^<]*)</([a-zA-Z0-9._\-]+)>')
          .allMatches(section)) {
    out[m.group(1)!] = m.group(2)!.trim();
  }
  return out;
}

/// Extract compile/runtime dependencies from a Maven POM (minimal).
List<MavenCoordinate> parsePomDependencies(String pomXml) {
  final deps = <MavenCoordinate>[];
  // Strip dependencyManagement / profiles / build sections first: their
  // <dependency> blocks are build-time tooling, not runtime deps.
  var scope = pomXml
      .replaceAll(
          RegExp(r'<dependencyManagement>[\s\S]*?</dependencyManagement>'), '')
      .replaceAll(RegExp(r'<profiles>[\s\S]*?</profiles>'), '')
      .replaceAll(RegExp(r'<build>[\s\S]*?</build>'), '');
  // <project> → keep only the top-level <dependencies> block when present.
  final ownDeps = RegExp(r'<dependencies>([\s\S]*?)</dependencies>')
      .allMatches(scope)
      .map((m) => m.group(1)!)
      .join('\n');
  if (ownDeps.isNotEmpty) scope = ownDeps;
  final depBlocks = RegExp(
    r'<dependency>([\s\S]*?)</dependency>',
    multiLine: true,
  ).allMatches(scope);
  for (final block in depBlocks) {
    final body = block.group(1)!;
    // skip test/provided
    final scope = RegExp(r'<scope>([^<]+)</scope>').firstMatch(body)?.group(1);
    if (scope == 'test' || scope == 'provided' || scope == 'system') continue;
    final optional = RegExp(r'<optional>true</optional>').hasMatch(body);
    if (optional) continue;

    final g = RegExp(r'<groupId>([^<]+)</groupId>').firstMatch(body)?.group(1);
    final a = RegExp(
      r'<artifactId>([^<]+)</artifactId>',
    ).firstMatch(body)?.group(1);
    var v = RegExp(r'<version>([^<]+)</version>').firstMatch(body)?.group(1) ?? '';
    // Version may be absent (managed by a parent POM) or a property
    // reference — both resolved later against the parent POM.
    if (g == null || a == null) continue;
    // Strip Maven version ranges: [1.1.7], (1.0,), etc. → first version token
    v = v.trim();
    if (v.startsWith('[') || v.startsWith('(')) {
      final m = RegExp(r'[\d][\d.]*').firstMatch(v);
      if (m == null) continue;
      v = m.group(0)!;
    }
    // Skip BOMs (no classes)
    if (a.endsWith('-bom') || a == 'bom') continue;
    final type =
        RegExp(r'<type>([^<]+)</type>').firstMatch(body)?.group(1) ?? 'jar';
    final packaging = type == 'aar' ? 'aar' : 'jar';
    // Heuristic: android-ish artifacts often aar
    final pack =
        (g.startsWith('androidx.') ||
            g.startsWith('com.android.') ||
            g.startsWith('com.google.android.') ||
            g.startsWith('ru.rustore.'))
        ? 'aar'
        : packaging;
    deps.add(
      MavenCoordinate(
        groupId: g.trim(),
        artifactId: a.trim(),
        version: v.trim(),
        packaging: pack,
      ),
    );
  }
  return deps;
}

/// Builds a minimal valid JAR (zip with empty META-INF) for tests.
List<int> minimalJarBytes({String entryName = 'META-INF/MANIFEST.MF'}) {
  final archive = Archive();
  final manifest = 'Manifest-Version: 1.0\n\n';
  archive.addFile(ArchiveFile(entryName, manifest.length, manifest.codeUnits));
  return ZipEncoder().encode(archive)!;
}

/// Builds a minimal AAR containing classes.jar for tests.
List<int> minimalAarBytes() {
  final classesJar = minimalJarBytes();
  final archive = Archive();
  archive.addFile(ArchiveFile('classes.jar', classesJar.length, classesJar));
  archive.addFile(
    ArchiveFile('AndroidManifest.xml', 11, '<manifest/>'.codeUnits),
  );
  return ZipEncoder().encode(archive)!;
}
