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
  }) : cacheRoot = cacheRoot ??
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
      return ResolvedJar(coordinate: working, jarPath: jarPath);
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
          print('⚠️  $working has no classes.jar (metadata AAR); using empty jar');
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
    if (coord.packaging == 'aar') {
      candidates.add(MavenCoordinate(
        groupId: coord.groupId,
        artifactId: coord.artifactId,
        version: coord.version,
        packaging: 'jar',
      ));
    } else if (coord.packaging == 'jar') {
      candidates.add(MavenCoordinate(
        groupId: coord.groupId,
        artifactId: coord.artifactId,
        version: coord.version,
        packaging: 'aar',
      ));
    }

    final client = httpClient ?? http.Client();
    try {
      for (final c in candidates) {
        final urls = <String>[
          for (final base in extraRepos)
            _repoUrl(base, c),
          googleMavenUrl(c),
        ];
        for (final url in urls) {
          if (verbose) {
            print('📥 Trying $c\n   $url');
          }
          final response = await client.get(Uri.parse(url));
          if (response.statusCode == 200 && response.bodyBytes.length > 32) {
            return (coord: c, bytes: response.bodyBytes);
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
      results.add(
        await resolve(
          coord,
          fixtureBytes: fixtures[coord.cacheKey],
        ),
      );
    }
    return results;
  }

  /// Resolve [roots] plus one level of POM transitive compile dependencies.
  Future<List<ResolvedJar>> resolveWithTransitives(
    List<MavenCoordinate> roots, {
    List<String> extraRepos = const [],
    int maxDepth = 2,
  }) async {
    final seen = <String>{};
    final out = <ResolvedJar>[];
    final queue = <({MavenCoordinate c, int depth})>[
      for (final r in roots) (c: r, depth: 0),
    ];

    while (queue.isNotEmpty) {
      final item = queue.removeAt(0);
      final key = item.c.cacheKey;
      if (!seen.add(key)) continue;
      try {
        final resolved = await resolve(
          item.c,
          extraRepos: extraRepos,
        );
        // Skip empty jars (metadata shells)
        final len = await File(resolved.jarPath).length();
        if (len > 200) {
          out.add(resolved);
        } else if (verbose) {
          print('   skip empty jar ${resolved.coordinate}');
        }

        // Prefer android/jvm variants when metadata-only
        if (len <= 200 && item.c.packaging == 'aar') {
          for (final suffix in ['-android', '-jvm', '-ktx']) {
            final alt = MavenCoordinate(
              groupId: item.c.groupId,
              artifactId: '${item.c.artifactId}$suffix',
              version: item.c.version,
              packaging: 'aar',
            );
            if (!seen.contains(alt.cacheKey)) {
              queue.add((c: alt, depth: item.depth));
            }
          }
        }

        if (item.depth < maxDepth) {
          final pomDeps = await _fetchPomDependencies(
            item.c,
            extraRepos: extraRepos,
          );
          for (final d in pomDeps) {
            if (!seen.contains(d.cacheKey)) {
              queue.add((c: d, depth: item.depth + 1));
            }
          }
        }
      } catch (e) {
        if (verbose) print('   resolve skip ${item.c}: $e');
      }
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
    final optional =
        RegExp(r'<optional>true</optional>').hasMatch(body);
    if (optional) continue;

    final g = RegExp(r'<groupId>([^<]+)</groupId>').firstMatch(body)?.group(1);
    final a =
        RegExp(r'<artifactId>([^<]+)</artifactId>').firstMatch(body)?.group(1);
    final v = RegExp(r'<version>([^<]+)</version>').firstMatch(body)?.group(1);
    if (g == null || a == null || v == null) continue;
    if (v.startsWith('\${')) continue;
    final type =
        RegExp(r'<type>([^<]+)</type>').firstMatch(body)?.group(1) ?? 'jar';
    final packaging = type == 'aar' ? 'aar' : 'jar';
    // Heuristic: android-ish artifacts often aar
    final pack = (g.startsWith('androidx.') ||
            g.startsWith('com.android.') ||
            g.startsWith('com.google.android.') ||
            g.startsWith('ru.rustore.'))
        ? 'aar'
        : packaging;
    deps.add(MavenCoordinate(
      groupId: g.trim(),
      artifactId: a.trim(),
      version: v.trim(),
      packaging: pack,
    ));
  }
  return deps;
}

/// Builds a minimal valid JAR (zip with empty META-INF) for tests.
List<int> minimalJarBytes({String entryName = 'META-INF/MANIFEST.MF'}) {
  final archive = Archive();
  final manifest = 'Manifest-Version: 1.0\n\n';
  archive.addFile(
    ArchiveFile(entryName, manifest.length, manifest.codeUnits),
  );
  return ZipEncoder().encode(archive)!;
}

/// Builds a minimal AAR containing classes.jar for tests.
List<int> minimalAarBytes() {
  final classesJar = minimalJarBytes();
  final archive = Archive();
  archive.addFile(
    ArchiveFile('classes.jar', classesJar.length, classesJar),
  );
  archive.addFile(
    ArchiveFile(
      'AndroidManifest.xml',
      11,
      '<manifest/>'.codeUnits,
    ),
  );
  return ZipEncoder().encode(archive)!;
}
