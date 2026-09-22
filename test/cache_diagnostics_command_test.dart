import 'dart:convert';
import 'dart:io';

import 'package:oka/oka.dart';
import 'package:oka/src/cli/cache_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, String> env;
  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'oka-diagnostic-cli-',
    );
    root = Directory(await temporary.resolveSymbolicLinks());
    env = {
      'HOME': root.path,
      'OKA_CACHE': p.join(root.path, 'shared'),
      'PUB_CACHE': p.join(root.path, 'pub'),
    };
  });
  tearDown(() => root.delete(recursive: true));

  Future<Map<String, dynamic>> run(List<String> args) async {
    final buffer = StringBuffer();
    await CacheCommand(
      environment: env,
      currentDirectory: root.path,
      out: buffer.writeln,
    ).run([...args, '--json']);
    return jsonDecode(buffer.toString()) as Map<String, dynamic>;
  }

  test(
    'stats preserves corrupt registry metadata and valid known projects without writing',
    () async {
      final project = p.join(root.path, 'project');
      final missing = p.join(root.path, 'missing');
      await Directory(p.join(project, '.oka_cache')).create(recursive: true);
      final registry = File(p.join(root.path, '.oka', 'cache-projects.json'));
      await registry.parent.create();
      final contents = jsonEncode({
        'schema_version': 1,
        'projects': [project, missing, 42],
      });
      await registry.writeAsString(contents);
      final result = await run([]);
      expect((result['discovery'] as Map)['projects'], [project]);
      expect((result['diagnostics'] as Map)['complete'], isFalse);
      expect((result['diagnostics'] as Map)['issues'], isNotEmpty);
      expect(await registry.readAsString(), contents);
      expect(File('${registry.path}.lock').existsSync(), isFalse);
      expect(jsonEncode(result['diagnostics']), contains(missing));
      await expectLater(run(['clean']), throwsFormatException);
    },
  );

  test(
    'kind filter preserves storage totals and issues, inspection creates no registry',
    () async {
      final project = p.join(root.path, '.oka_cache', 'build');
      await Directory(project).create(recursive: true);
      await File(p.join(project, 'artifact')).writeAsString('1234');
      final all = await run([]);
      final selected = await run(['--kind', 'registry']);
      expect(selected['total_bytes'], all['total_bytes']);
      final records = (selected['diagnostics'] as Map)['records'] as List;
      expect(records, isNotEmpty);
      expect(records.every((r) => (r as Map)['kind'] == 'registry'), isTrue);
      expect(
        File(p.join(root.path, '.oka', 'cache-projects.json')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'Apple metadata is recorded separately from unknown runtime state',
    () async {
      final device = Directory(p.join(root.path, 'device'));
      await device.create();
      await File(p.join(device.path, 'device.plist')).writeAsString('fixture');
      final storage = await StorageInventory(
        locations: [
          StorageLocation(
            id: 'device',
            path: device.path,
            category: 'apple-simulator-devices',
            platform: 'apple',
            ownership: 'user',
            prunable: false,
          ),
        ],
      ).scan();
      final provider = AppleCacheDiagnosticProvider(
        readPlist: (_) async => {
          'name': 'iPhone fixture',
          'UDID': 'fixture-udid',
          'runtime': 'iOS-fixture',
          'state': 3,
          'private_key': 'omit',
        },
      );
      final contribution = await provider.inspect(
        CacheDiagnosticContext(
          projects: [],
          environment: env,
          storage: storage,
        ),
      );
      final record = contribution.records.single;
      expect(record.label, 'iPhone fixture');
      expect(record.metadata['runtime_status'], 'unknown');
      expect(jsonEncode(record.toJson()), isNot(contains('private_key')));
      expect(contribution.issues, isEmpty);
    },
  );

  test('native plist decoder reads XML and binary formats', () async {
    final file = File(p.join(root.path, 'device.plist'));
    await file.writeAsString(
      '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>name</key><string>Fixture</string></dict></plist>',
    );
    expect((await readAppleDiagnosticPlist(file.path))['name'], 'Fixture');
    final conversion = await Process.run('/usr/bin/plutil', [
      '-convert',
      'binary1',
      file.path,
    ]);
    expect(conversion.exitCode, 0);
    expect((await readAppleDiagnosticPlist(file.path))['name'], 'Fixture');
  }, skip: !Platform.isMacOS);
}
