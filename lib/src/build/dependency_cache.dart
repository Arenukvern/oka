import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// A Maven coordinate for Android dependencies.
class MavenCoordinate {
  final String groupId;
  final String artifactId;
  final String version;
  final String packaging; // jar | aar

  const MavenCoordinate({
    required this.groupId,
    required this.artifactId,
    required this.version,
    this.packaging = 'jar',
  });

  String get pathSegment =>
      '${groupId.replaceAll('.', '/')}/$artifactId/$version';

  String get fileName => packaging == 'pom'
      ? '$artifactId-$version.pom'
      : '$artifactId-$version.$packaging';

  String get cacheKey => '$groupId:$artifactId:$version:$packaging';

  /// Parses `group:artifact:version` (packaging auto-detected via KMP
  /// suffix probing at resolve time).
  static MavenCoordinate? parse(String coordinate) {
    final parts = coordinate.split(':');
    if (parts.length != 3) return null;
    if (parts.any((p) => p.trim().isEmpty)) return null;
    return MavenCoordinate(
      groupId: parts[0].trim(),
      artifactId: parts[1].trim(),
      version: parts[2].trim(),
    );
  }

  @override
  String toString() => '$groupId:$artifactId:$version@$packaging';
}

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

/// Builds a Maven URL for [coord] (Google Maven for androidx, Central otherwise).
String googleMavenUrl(MavenCoordinate coord) {
  if (coord.groupId.startsWith('androidx.') ||
      coord.groupId.startsWith('com.google.android.') ||
      coord.groupId.startsWith('com.android.') ||
      coord.groupId == 'com.android.support') {
    // Prefer the real Google Maven storage host (maven.google.com 301s here).
    return 'https://dl.google.com/dl/android/maven2/'
        '${coord.pathSegment}/${coord.fileName}';
  }
  return 'https://repo1.maven.org/maven2/${coord.pathSegment}/${coord.fileName}';
}

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

  const ResolvedJar({required this.coordinate, required this.jarPath});
}

/// Caches Maven artifacts under `~/.oka/cache/maven` (or custom root).
class DependencyCache {
  final String cacheRoot;
  final bool verbose;
  final http.Client? httpClient;
  final bool allowNetwork;

  DependencyCache({
    String? cacheRoot,
    this.verbose = false,
    this.httpClient,
    this.allowNetwork = true,
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
  }) async {
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
      final downloaded = await _downloadArtifact(
        working,
        extraRepos: extraRepos,
      );
      bytes = downloaded.bytes;
      working = downloaded.coord;
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
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 30));
            if (response.statusCode == 200 && response.bodyBytes.length > 32) {
              return (coord: c, bytes: response.bodyBytes);
            }
          } catch (_) {
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

  /// Repo order: platform-appropriate first (avoid thrashing VK artifactory
  /// for every AndroidX artifact).
  List<String> _candidateUrls(MavenCoordinate c, List<String> extraRepos) {
    final urls = <String>[];
    final isGoogle =
        c.groupId.startsWith('androidx.') ||
        c.groupId.startsWith('com.android.') ||
        c.groupId.startsWith('com.google.android.');
    final isCentral =
        c.groupId.startsWith('org.jetbrains') ||
        c.groupId.startsWith('com.squareup') ||
        c.groupId.startsWith('org.slf4j') ||
        c.groupId.startsWith('javax.');
    final isCustom =
        c.groupId.startsWith('ru.rustore') || c.groupId.startsWith('ru.vk');

    void add(String u) {
      if (!urls.contains(u)) urls.add(u);
    }

    if (isCustom) {
      for (final base in extraRepos) {
        add(_repoUrl(base, c));
      }
    }
    if (isGoogle) {
      add(googleMavenUrl(c));
      // AndroidX jars sometimes only on Maven Central as -jvm
      add('https://repo1.maven.org/maven2/${c.pathSegment}/${c.fileName}');
    } else if (isCentral) {
      add('https://repo1.maven.org/maven2/${c.pathSegment}/${c.fileName}');
      add(googleMavenUrl(c));
    } else {
      add(googleMavenUrl(c));
      add('https://repo1.maven.org/maven2/${c.pathSegment}/${c.fileName}');
    }
    if (!isCustom) {
      for (final base in extraRepos) {
        add(_repoUrl(base, c));
      }
    }
    return urls;
  }

  String _repoUrl(String base, MavenCoordinate coord) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/${coord.pathSegment}/${coord.fileName}';
  }

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
    int maxDepth = 1,
    int maxArtifacts = 60,
  }) async {
    final seen = <String>{};
    final out = <ResolvedJar>[];
    final queue = <({MavenCoordinate c, int depth})>[
      for (final r in roots) (c: r, depth: 0),
    ];
    var iterations = 0;
    const maxIterations = 120;

    while (queue.isNotEmpty &&
        out.length < maxArtifacts &&
        iterations < maxIterations) {
      iterations++;
      final item = queue.removeAt(0);
      final key = item.c.cacheKey;
      if (!seen.add(key)) continue;
      try {
        final resolved = await resolve(item.c, extraRepos: extraRepos);
        final len = await File(resolved.jarPath).length();
        if (len > 200) {
          out.add(resolved);
        } else if (verbose) {
          print('   skip empty jar ${resolved.coordinate}');
        }

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
              queue.add((c: alt, depth: item.depth));
            }
          }
        }

        if (item.depth < maxDepth && out.length < maxArtifacts) {
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
              queue.add((c: d, depth: item.depth + 1));
            }
          }
        }
      } catch (e) {
        if (verbose) print('   resolve skip ${item.c}: $e');
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
    return parsePomDependencies(String.fromCharCodes(bytes));
  }
}

/// Extract compile/runtime dependencies from a Maven POM (minimal).
List<MavenCoordinate> parsePomDependencies(String pomXml) {
  final deps = <MavenCoordinate>[];
  final depBlocks = RegExp(
    r'<dependency>([\s\S]*?)</dependency>',
    multiLine: true,
  ).allMatches(pomXml);
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
    var v = RegExp(r'<version>([^<]+)</version>').firstMatch(body)?.group(1);
    if (g == null || a == null || v == null) continue;
    if (v.startsWith('\${')) continue;
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
