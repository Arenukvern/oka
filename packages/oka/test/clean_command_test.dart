import 'dart:io';

import 'package:oka/src/cli/clean_command.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// ADR-0028 §1: `oka clean --full` cleans the real dependency-cache roots —
/// the shared artifact store's maven tree and the legacy remainders — not
/// only the stale `~/.oka_cache/maven` path nothing writes anymore.
void main() {
  late Directory temp;
  late String home;
  final output = <String>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_clean_full_');
    home = p.join(temp.path, 'home');
    Directory(home).createSync(recursive: true);
    output.clear();
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  CleanCommand command() => CleanCommand(
    inspectSessionStates: () async => const SessionStateRegistrySnapshot(),
    currentDirectory: p.join(temp.path, 'project'),
    environment: {'HOME': home, 'USERPROFILE': home},
    output: output.add,
  );

  test('cleans store maven, legacy cache root, and the grandfathered root',
      () async {
    final storeMaven = Directory(
      p.join(home, '.oka', 'store', 'maven', 'io', 'test', '1.0'),
    )..createSync(recursive: true);
    File(p.join(storeMaven.path, 'a.jar')).writeAsStringSync('store');
    final legacyMaven = Directory(
      p.join(home, '.oka', 'cache', 'maven', 'io', 'test', '1.0'),
    )..createSync(recursive: true);
    File(p.join(legacyMaven.path, 'b.jar')).writeAsStringSync('legacy');
    final oldestMaven = Directory(p.join(home, '.oka_cache', 'maven'))
      ..createSync(recursive: true);
    File(p.join(oldestMaven.path, 'c.jar')).writeAsStringSync('oldest');

    await command().run(['--full']);

    expect(storeMaven.existsSync(), isFalse);
    expect(legacyMaven.existsSync(), isFalse);
    expect(oldestMaven.existsSync(), isFalse);
  });

  test('absent roots are reported, not fatal', () async {
    await command().run(['--full']);
    expect(output.join('\n'), contains('Clean complete'));
  });

  test('clean without --full leaves dependency caches alone', () async {
    final storeMaven = Directory(
      p.join(home, '.oka', 'store', 'maven', 'io', 'test', '1.0'),
    )..createSync(recursive: true);

    await command().run(const []);

    expect(storeMaven.existsSync(), isTrue);
  });
}
