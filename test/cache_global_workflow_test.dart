import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/cache_command.dart';
import 'package:oka/src/cli/cache_workspace.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Map<String, String> environment;
  late String first;
  late String second;
  late String workspace;

  Future<void> write(String path, [String content = 'fixture']) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  String output(String project) =>
      p.join(project, '.oka_cache', 'build', 'web', 'app.js');
  String profile(String project) =>
      p.join(project, '.oka_cache', 'chrome-profiles', 'session', 'cookies');

  Future<Map<String, dynamic>> run(
    List<String> args, {
    bool rejects = false,
  }) async {
    final buffer = StringBuffer();
    final operation = CacheCommand(
      environment: environment,
      currentDirectory: temp.path,
      out: buffer.writeln,
    ).run([...args, '--json']);
    if (rejects) {
      await expectLater(
        operation,
        throwsA(
          isA<CacheCommandError>().having(
            (error) => error.exitCode,
            'exitCode',
            1,
          ),
        ),
      );
    } else {
      await operation;
    }
    return jsonDecode(buffer.toString()) as Map<String, dynamic>;
  }

  Future<String> save() async {
    final path = p.join(temp.path, 'cleanup.json');
    await run([
      'clean',
      '--scan',
      workspace,
      '--scope',
      'build',
      '--save-plan',
      path,
    ]);
    return path;
  }

  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'oka-global-workflow-',
    );
    temp = Directory(await created.resolveSymbolicLinks());
    workspace = p.join(temp.path, 'workspace');
    first = p.join(workspace, 'first');
    second = p.join(workspace, 'second');
    environment = {
      'HOME': p.join(temp.path, 'home'),
      'OKA_CACHE': p.join(temp.path, 'shared'),
      'ANDROID_HOME': p.join(temp.path, 'android'),
      'ANDROID_SDK_ROOT': p.join(temp.path, 'android'),
      'PUB_CACHE': p.join(temp.path, 'pub'),
    };
    await write(output(first));
    await write(output(second));
    await write(profile(first), 'user cookies');
    await write(profile(second), 'user cookies');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'scan remembers both projects and default global cleanup reaches both',
    () async {
      final preview = await run([
        'clean',
        '--scan',
        workspace,
        '--scope',
        'build',
      ]);
      expect((preview['discovery'] as Map)['projects'], [first, second]);
      expect((preview['selected'] as List).length, 2);
      expect(await File(output(first)).exists(), isTrue);
      final resolved = await loadCacheWorkspace(
        environment: environment,
        currentDirectory: temp.path,
      );
      expect(resolved.projects, [first, second]);
      final applied = await run(['clean', '--scope', 'build', '--apply']);
      expect((applied['deleted'] as List).length, 2);
      for (final project in [first, second]) {
        expect(await File(output(project)).exists(), isFalse);
        expect(await File(profile(project)).readAsString(), 'user cookies');
      }
    },
  );

  test(
    'explicit project cleanup leaves another registered project intact',
    () async {
      await run(['clean', '--scan', workspace]);
      final applied = await run([
        'clean',
        '--project',
        first,
        '--scope',
        'build',
        '--apply',
      ]);
      expect((applied['discovery'] as Map)['mode'], 'project');
      expect(await File(output(first)).exists(), isFalse);
      expect(await File(output(second)).exists(), isTrue);
    },
  );

  test(
    'default cleanup includes shared cache alongside known projects',
    () async {
      final shared = p.join(environment['OKA_CACHE']!, 'maven', 'artifact.jar');
      await write(shared, 'shared dependency');
      final preview = await run(['clean', '--scan', workspace]);
      expect((preview['selected'] as List).length, 3);
      expect(await File(shared).exists(), isTrue);
      final applied = await run(['clean', '--apply']);
      expect((applied['deleted'] as List).length, 3);
      expect(await File(shared).exists(), isFalse);
      expect(await File(profile(first)).exists(), isTrue);
    },
  );

  test('saved plan applies only reviewed candidates', () async {
    final plan = await save();
    final newOutput = p.join(
      first,
      '.oka_cache',
      'build',
      'new-platform',
      'artifact',
    );
    await write(newOutput);
    final applied = await run(['clean', '--apply-plan', plan]);
    expect((applied['deleted'] as List).length, 2);
    expect(await File(newOutput).exists(), isTrue);
    expect(await File(profile(first)).exists(), isTrue);
  });

  test('saved plan rejects output changed after preview', () async {
    final plan = await save();
    await write(output(first), 'changed artifact with different size');
    final applied = await run(['clean', '--apply-plan', plan], rejects: true);
    expect(applied['errors'], isNotEmpty);
    expect(await File(output(first)).exists(), isTrue);
    expect(await File(output(second)).exists(), isFalse);
  });

  test('saved plan rechecks newly added profile protections', () async {
    final plan = await save();
    final cookies = p.join(
      first,
      '.oka_cache',
      'build',
      'web',
      'chrome-profiles',
      'cookies',
    );
    await write(cookies, 'new session');
    final applied = await run(['clean', '--apply-plan', plan], rejects: true);
    expect(applied['errors'], isNotEmpty);
    expect(await File(cookies).exists(), isTrue);
    expect(await File(output(first)).exists(), isTrue);
  });

  test('saved plan rechecks uncertain process leases', () async {
    final plan = await save();
    await write(
      p.join(first, '.oka_cache', 'processes', 'uncertain.json'),
      '{malformed',
    );
    final applied = await run(['clean', '--apply-plan', plan], rejects: true);
    expect(applied['errors'], isNotEmpty);
    expect(await File(output(first)).exists(), isTrue);
    expect(await File(output(second)).exists(), isFalse);
  });

  test('JSON next action preserves scope age size and targeting', () async {
    final preview = await run([
      'clean',
      '--project',
      first,
      '--scope',
      'build',
      '--older-than',
      '30d',
      '--max-size',
      '1GB',
    ]);
    final actions = preview['next_actions'] as List;
    final encoded = jsonEncode(actions);
    for (final token in [
      '--project',
      first,
      '--scope',
      'build',
      '--older-than',
      '30d',
      '--max-size',
      '1GB',
      '--apply',
    ]) {
      expect(encoded, contains(token));
    }
    expect(await File(output(first)).exists(), isTrue);
  });

  test(
    'schema is filesystem independent and overview defaults to stats',
    () async {
      final schema = await run(['schema']);
      expect(schema['schema_version'], 'oka.cache.interface.v1');
      expect(await Directory(environment['HOME']!).exists(), isFalse);
      final buffer = StringBuffer();
      await CacheCommand(
        inventory: StorageInventory(locations: const []),
        out: buffer.writeln,
      ).run([]);
      expect(buffer.toString(), contains('storage'));
    },
  );

  test(
    'interactive refuses nonterminal input without deleting caches',
    () async {
      if (stdin.hasTerminal && stdout.hasTerminal) return;
      await expectLater(
        CacheCommand(
          environment: environment,
          currentDirectory: first,
          out: (_) {},
        ).run(['clean', '--interactive']),
        throwsA(isA<CacheCommandError>()),
      );
      expect(await File(output(first)).exists(), isTrue);
      expect(await Directory(environment['HOME']!).exists(), isFalse);
    },
  );
}
