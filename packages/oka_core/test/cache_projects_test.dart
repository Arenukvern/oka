import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late CacheProjectRegistry registry;
  setUp(() async {
    final raw = await Directory.systemTemp.createTemp('oka-projects-');
    temporary = Directory(await raw.resolveSymbolicLinks());
    registry = CacheProjectRegistry(
      path: p.join(temporary.path, 'state', 'registry.json'),
    );
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<String> project(String name) async {
    final path = p.join(temporary.path, name);
    await Directory(p.join(path, '.oka_cache')).create(recursive: true);
    return path;
  }

  test('defaults registry outside prunable storage', () {
    expect(
      CacheProjectRegistry(environment: {'HOME': temporary.path}).path,
      p.join(temporary.path, '.oka', 'cache-projects.json'),
    );
  });

  test(
    'registers canonical paths, deduplicates and filters stale caches',
    () async {
      final a = await project('a');
      final b = await project('b');
      await registry.register(b);
      await registry.register(p.join(a, '.'));
      await registry.register(a);
      expect(await registry.projects(), [a, b]);
      await Directory(p.join(a, '.oka_cache')).delete();
      expect(await registry.projects(), [b]);
      expect(
        (jsonDecode(await File(registry.path).readAsString())
            as Map)['projects'],
        [a, b],
      );
    },
  );

  test(
    'scans root and nested projects while skipping generated directories and links',
    () async {
      final root = await project('workspace');
      final nested = await project('workspace/packages/app');
      await project('workspace/node_modules/dependency');
      await project('workspace/.hidden/project');
      final outside = await project('outside');
      await Link(p.join(root, 'linked')).create(outside);
      final result = await registry.discover([root, root]);
      expect(result.complete, isTrue);
      expect(result.projects, [root, nested]);
      expect(await registry.projects(), result.projects);
      expect(result.toJson()['complete'], isTrue);
    },
  );

  test(
    'discovery preserves projects registered outside requested roots',
    () async {
      final old = await project('old');
      final fresh = await project('fresh');
      await registry.register(old);
      await registry.discover([fresh]);
      expect(await registry.projects(), [fresh, old]);
    },
  );

  test('depth and directory bounds report incomplete discovery', () async {
    final root = await project('root');
    await project('root/nested');
    final depth = await registry.discover([root], maxDepth: 0);
    expect(depth.complete, isFalse);
    expect(depth.projects, [root]);
    final count = await registry.discover([root], maxDirectories: 1);
    expect(count.complete, isFalse);
    expect(count.warnings.single, contains('Directory limit'));
  });

  test(
    'missing roots report incompleteness without creating registry',
    () async {
      final result = await registry.discover([
        p.join(temporary.path, 'missing'),
      ]);
      expect(result.complete, isFalse);
      expect(await File(registry.path).exists(), isFalse);
    },
  );

  test('refuses filesystem root and invalid bounds', () async {
    await expectLater(registry.discover([p.separator]), throwsArgumentError);
    await expectLater(registry.discover([], maxDepth: -1), throwsArgumentError);
    await expectLater(
      registry.discover([], maxDirectories: 0),
      throwsArgumentError,
    );
  });

  test('malformed metadata fails visibly and is never overwritten', () async {
    final app = await project('app');
    final file = File(registry.path);
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');
    await expectLater(registry.projects(), throwsFormatException);
    await expectLater(registry.register(app), throwsFormatException);
    await expectLater(registry.discover([app]), throwsFormatException);
    expect(await file.readAsString(), '{broken');
  });

  test('registering an existing project leaves registry unchanged', () async {
    final app = await project('app');
    await registry.register(app);
    final file = File(registry.path);
    final sentinel = DateTime(2001);
    await file.setLastModified(sentinel);
    await registry.register(app);
    expect(await file.lastModified(), sentinel);
  });

  test('concurrent registrations preserve every project', () async {
    final paths = await Future.wait(
      List.generate(15, (index) => project('app-$index')),
    );
    await Future.wait(
      paths.map(
        (path) => CacheProjectRegistry(path: registry.path).register(path),
      ),
    );
    expect(await registry.projects(), paths..sort());
  });

  test('registered ancestor links cannot redirect the inventory', () async {
    final original = await project('parent/app');
    await registry.register(original);
    await Directory(
      p.join(temporary.path, 'parent'),
    ).rename(p.join(temporary.path, 'moved'));
    await Link(
      p.join(temporary.path, 'parent'),
    ).create(p.join(temporary.path, 'moved'));
    expect(await registry.projects(), isEmpty);
  });

  test('rejects registry paths that normalize to filesystem root', () async {
    final file = File(registry.path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schema_version': 1,
        'projects': ['/project/..'],
      }),
    );
    await expectLater(registry.projects(), throwsFormatException);
  });

  test('symlink cache markers are excluded', () async {
    final outside = await project('outside');
    final root = await Directory(p.join(temporary.path, 'root')).create();
    await Link(
      p.join(root.path, '.oka_cache'),
    ).create(p.join(outside, '.oka_cache'));
    expect((await registry.discover([root.path])).projects, isEmpty);
  });
}
