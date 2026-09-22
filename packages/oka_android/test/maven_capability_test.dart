import 'dart:convert';

import 'package:oka_android/src/maven_resolver.dart';
import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

class _RecordingTransport implements MavenTransport {
  final calls = <Uri>[];

  @override
  Future<List<int>?> get(Uri uri) async {
    calls.add(uri);
    return minimalJarBytes();
  }
}

class _MemoryRepository implements MavenArtifactRepository {
  final bytes = <String, List<int>>{};
  final text = <String, String>{};

  @override
  Future<void> delete(String path) async {
    bytes.remove(path);
    text.remove(path);
  }

  @override
  Future<bool> exists(String path) async =>
      bytes.containsKey(path) || text.containsKey(path);

  @override
  Future<int> length(String path) async =>
      bytes[path]?.length ?? text[path]?.length ?? 0;

  @override
  Future<List<int>> readBytes(String path) async =>
      bytes[path] ?? utf8.encode(text[path]!);

  @override
  Future<String> readText(String path) async =>
      text[path] ?? utf8.decode(bytes[path]!);

  @override
  Future<void> writeBytes(
    String path,
    List<int> value, {
    bool flush = false,
  }) async {
    bytes[path] = [...value];
  }

  @override
  Future<void> writeText(
    String path,
    String value, {
    bool flush = false,
  }) async {
    text[path] = value;
  }
}

void main() {
  test(
    'resolver uses injected routing, transport and artifact repository',
    () async {
      final transport = _RecordingTransport();
      final repository = _MemoryRepository();
      final router = MavenRepositoryRouter(
        routes: const [(prefix: 'dev.vendor', host: MavenHost.vendor)],
      );
      final resolver = MavenResolver(
        cacheRoot: '/virtual/maven',
        transport: transport,
        artifactRepository: repository,
        repositoryRouter: router,
        userRepos: const ['https://vendor.example/repository'],
      );
      const coordinate = MavenCoordinate(
        groupId: 'dev.vendor.sdk',
        artifactId: 'runtime',
        version: '1.0.0',
      );

      final first = await resolver.resolve(coordinate);
      final second = await resolver.resolve(coordinate);

      expect(first.jarPath, second.jarPath);
      expect(transport.calls, hasLength(1), reason: 'per-resolver memoization');
      expect(transport.calls.single.host, 'vendor.example');
      expect(repository.bytes[first.jarPath], isNotEmpty);
    },
  );

  test('metadata policy parses parent, BOM and Android runtime module', () {
    const parser = MavenMetadataParser();
    const pom = '''
<project><parent><groupId>dev.parent</groupId><artifactId>platform</artifactId>
<version>2.0</version></parent><dependencyManagement><dependencies><dependency>
<groupId>dev.bom</groupId><artifactId>catalog</artifactId><version>3.0</version>
<type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement></project>
''';
    expect(parser.parent(pom)?.artifactId, 'platform');
    expect(parser.imports(pom).single.packaging, 'pom');
    const module =
        '''{"variants":[{"name":"androidRuntimeElements","dependencies":[{"group":"dev.runtime","module":"core","version":{"requires":"4.0"}}]},{"name":"iosRuntimeElements","dependencies":[{"group":"bad","module":"ios","version":{"requires":"1"}}]}]}''';
    expect(parser.moduleRuntimeDependencies(module).single.artifactId, 'core');
  });

  test(
    'transitive graph keeps all metadata I/O behind repository seam',
    () async {
      final transport = _RecordingTransport();
      final repository = _MemoryRepository();
      final resolver = MavenResolver(
        cacheRoot: '/virtual/maven',
        transport: transport,
        artifactRepository: repository,
      );
      const root = MavenCoordinate(
        groupId: 'dev.example',
        artifactId: 'root',
        version: '1.0.0',
      );
      repository.bytes[resolver.localPathFor(root)] = List<int>.filled(300, 1);
      final pom = MavenCoordinate(
        groupId: root.groupId,
        artifactId: root.artifactId,
        version: root.version,
        packaging: 'pom',
      );
      repository.text[resolver.localPathFor(pom)] =
          '<project><dependencies></dependencies></project>';

      final failures = <Object>[];
      final resolved = await resolver.resolveWithTransitives([
        root,
      ], onFailure: (_, error) => failures.add(error));

      expect(failures, isEmpty);
      expect(resolved.map((entry) => entry.coordinate), [root]);
      expect(
        transport.calls.where((uri) => uri.path.endsWith('.module')),
        isNotEmpty,
        reason: 'optional module metadata still uses the injected transport',
      );
    },
  );
}
