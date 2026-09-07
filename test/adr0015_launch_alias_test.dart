// ADR-0015 C1 — `oka launch` is an alias of `oka run device`.
//
// The dispatch equivalence is proven end-to-end against a sandbox project
// whose entrypoint (test/fixtures/adr0015_device_entrypoint.dart) declares a
// *test double* target named `device` — same dispatch path, no adb/device.
//
// Asserted:
// * `oka launch` and `oka run device` produce byte-identical output and the
//   same exit code (the alias delegates through RunCommand);
// * the historical portable flags still work (`--device`/`-d`, `--verbose`
//   forwarded to the entrypoint);
// * flags that moved behind the typed target config fail with the
//   migration message instead of leaking into the dispatcher.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late String relBin;

  Future<ProcessResult> okaCli(final List<String> args) => Process.run(
        'dart',
        ['run', relBin, ...args],
        workingDirectory: sandbox.path,
      );

  setUp(() async {
    sandbox = Directory(
      p.join(
        Directory.current.path,
        '.oka_cache',
        'adr0015_launch_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await Directory(p.join(sandbox.path, 'tool')).create(recursive: true);
    File(
      p.join(Directory.current.path, 'test/fixtures/adr0015_device_entrypoint.dart'),
    ).copySync(p.join(sandbox.path, 'tool', 'oka_pipeline.dart'));
    relBin = p.relative(
      p.join(Directory.current.path, 'bin', 'oka.dart'),
      from: sandbox.path,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  File marker() => File(
        p.join(sandbox.path, '.oka_cache', 'build', 'debug', 'device-ran.txt'),
      );

  group('oka launch ≡ oka run device', () {
    test('identical output and exit code for the same dispatch', () async {
      final viaLaunch = await okaCli(['launch']);
      final viaRun = await okaCli(['run', 'device']);
      expect(viaLaunch.exitCode, 0, reason: viaLaunch.stderr as String);
      expect(viaRun.exitCode, 0, reason: viaRun.stderr as String);
      expect(viaLaunch.stdout, viaRun.stdout);
      expect(await marker().exists(), isTrue);
    });

    test('bare `oka launch` reaches the device target', () async {
      final result = await okaCli(['launch']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(await marker().readAsString(), contains('"verbose":false'));
    });
  });

  group('launch flags', () {
    test('-d <serial> forwards as the device invocation arg', () async {
      for (final flagValue in const [
        ['--device', 'FAKE123'],
        ['-d', 'FAKE123'],
      ]) {
        final result = await okaCli(['launch', ...flagValue]);
        expect(result.exitCode, 0,
            reason: '${flagValue}: ${result.stderr}');
        expect(await marker().readAsString(), contains('FAKE123'));
      }
    });

    test('bare --device is a usage error (option now takes a value)', () async {
      final result = await okaCli(['launch', '--device']);
      expect(result.exitCode, isNot(0));
    });

    test('unknown invocation args are rejected by the target contract', () async {
      final result = await okaCli([
        'launch',
        '--oka-target-arg',
        'bogus=1',
      ]);
      expect(result.exitCode, isNot(0));
    });

    test('--verbose is forwarded to the entrypoint', () async {
      final result = await okaCli(['launch', '--verbose']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(await marker().readAsString(), contains('"verbose":true'));
    });

    test('--help documents the alias, exits 0', () async {
      final result = await okaCli(['launch', '--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('oka run device'));
      expect(result.stdout, contains('DeviceTarget'));
    });

    test('flags moved behind the typed target config fail with the '
        'migration path (no leakage into the dispatcher)', () async {
      for (final flag in const [
        '--apk',
        '--package',
        '--activity',
        '--no-install',
        '--wait',
      ]) {
        final result = await okaCli(['launch', flag]);
        expect(result.exitCode, 2, reason: flag);
        expect(result.stderr, contains('moved behind the device target'));
        expect(result.stderr, contains('DeviceTarget('));
        expect(await marker().exists(), isFalse);
      }
    });
  });
}
