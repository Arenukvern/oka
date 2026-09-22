import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/cache_command.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory build;
  late Directory device;
  late StringBuffer output;
  late CacheCommand command;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_cache_cli_');
    temp = Directory(await temp.resolveSymbolicLinks());
    build = await Directory(p.join(temp.path, 'build')).create();
    device = await Directory(p.join(temp.path, 'device')).create();
    await File(p.join(build.path, 'output')).writeAsString('build');
    await File(p.join(device.path, 'userdata')).writeAsString('user data');
    output = StringBuffer();
    command = CacheCommand(
      out: output.writeln,
      store: LocalArtifactStore(root: p.join(temp.path, 'missing-store')),
      inventory: StorageInventory(
        locations: [
          StorageLocation(
            id: 'build',
            path: build.path,
            category: 'build',
            platform: 'any',
            ownership: 'oka',
            prunable: true,
            scope: 'build',
          ),
          StorageLocation(
            id: 'device',
            path: device.path,
            category: 'emulator',
            platform: 'android',
            ownership: 'external',
            prunable: false,
          ),
        ],
      ),
    );
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('stats JSON includes measured storage and platform data', () async {
    await command.run(['stats', '--json']);
    final json = jsonDecode(output.toString()) as Map<String, dynamic>;
    expect(json['schema_version'], 'oka.cache.stats.v1');
    expect(output.toString(), contains(device.path));
    expect(output.toString(), contains('android'));
    expect(await build.exists(), isTrue);
  });

  test('two-command preview/apply only deletes eligible build data', () async {
    await command.run(['prune', '--json']);
    final preview = jsonDecode(output.toString()) as Map<String, dynamic>;
    expect(preview['schema_version'], 'oka.cache.prune.v1');
    expect(await build.exists(), isTrue);
    output.clear();
    await command.run(['prune', '--apply', '--json']);
    expect(jsonDecode(output.toString()), isA<Map<String, dynamic>>());
    expect(await build.exists(), isFalse);
    expect(
      await File(p.join(device.path, 'userdata')).readAsString(),
      'user data',
    );
  });

  test('scope filters do not delete unrelated locations', () async {
    await command.run(['prune', '--scope=tools', '--apply']);
    expect(await build.exists(), isTrue);
    expect(output.toString(), contains('Deleted 0'));
  });

  test('relative project paths in saved plans map to CLI usage errors',
      () async {
    final plan = File(p.join(temp.path, 'invalid-plan.json'));
    await plan.writeAsString(jsonEncode({
      'schema': StorageCleanupPlan.schema,
      'selected': const <Object?>[],
      'projects': ['relative/project'],
    }));
    final operation = CacheCommand(
      environment: {'HOME': p.join(temp.path, 'home')},
      currentDirectory: temp.path,
      out: (_) {},
    ).run(['clean', '--apply-plan', plan.path]);
    await expectLater(
      operation,
      throwsA(
        isA<CacheCommandError>().having(
          (error) => error.exitCode,
          'exitCode',
          64,
        ),
      ),
    );
  });

  test('help-advertised binary size spellings work for gc and prune', () async {
    for (final size in ['2G', '2GB', '2GiB', '500MB', '123B']) {
      output.clear();
      await command.run(['gc', '--max-size=$size', '--dry-run']);
      expect(output.toString(), contains('Would purge 0'));
      output.clear();
      await command.run(['prune', '--max-size=$size']);
      expect(output.toString(), contains('Would prune 0'));
    }
    expect(await build.exists(), isTrue);
  });

  test(
    'invalid selection and conflicting execution flags fail before deletion',
    () async {
      for (final args in [
        ['prune', '--apply', '--dry-run'],
        ['prune', '--older-than=yesterday', '--apply'],
        ['prune', '--max-size=-1', '--apply'],
        ['prune', '--max-size=18014398509481984K', '--apply'],
        ['prune', '--older-than=9223372036854775807d', '--apply'],
        ['prune', 'unexpected', '--apply'],
      ]) {
        await expectLater(command.run(args), throwsA(isA<CacheCommandError>()));
        expect(await build.exists(), isTrue);
      }
    },
  );

  test('help exposes stats, prune, and preview semantics', () async {
    await command.run(['--help']);
    expect(output.toString(), contains('stats'));
    expect(output.toString(), contains('prune'));
    output.clear();
    await command.run(['prune', '--help']);
    expect(output.toString(), contains('--apply'));
    expect(output.toString(), contains('Preserves SDKs'));
  });

  test(
    'CLI entrypoint applies to an explicit project and keeps JSON clean',
    () async {
      final project = await Directory(p.join(temp.path, 'project')).create();
      final artifact = File(
        p.join(project.path, '.oka_cache', 'build', 'web', 'app.js'),
      );
      await artifact.parent.create(recursive: true);
      await artifact.writeAsString('fixture');
      final profile = File(
        p.join(
          project.path,
          '.oka_cache',
          'build',
          'web',
          'chrome-profiles',
          'main',
          'state',
        ),
      );
      await profile.parent.create(recursive: true);
      await profile.writeAsString('preserve');
      final entrypoint = p.absolute('packages', 'oka', 'bin', 'oka.dart');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          entrypoint,
          'cache',
          'prune',
          '--project',
          project.path,
          '--scope=build',
          '--apply',
          '--json',
        ],
        environment: {
          'HOME': temp.path,
          'USERPROFILE': temp.path,
          'OKA_CACHE': p.join(temp.path, 'shared'),
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['schema_version'], 'oka.cache.prune.v1');
      expect(json['freed_bytes'], 7);
      expect(await artifact.exists(), isFalse);
      expect(await profile.readAsString(), 'preserve');
      final invalid = await Process.run(Platform.resolvedExecutable, [
        entrypoint,
        'cache',
        'prune',
        '--apply',
        '--dry-run',
        '--json',
      ]);
      expect(invalid.exitCode, 64);
      expect(invalid.stdout, isEmpty);
      expect(invalid.stderr, contains('Choose --apply or --dry-run'));
    },
  );
}
