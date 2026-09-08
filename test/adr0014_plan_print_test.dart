// ADR-0014 — dry-run plan printing through target dispatch (the dry-run
// law catching up to implementation: a successful dry-run publish dispatch
// MUST print the plan; platform build dispatch output is unchanged).
//
// The dispatch tests run the real entrypoint (`dart run
// test/fixtures/adr0014_plan_print_entrypoint.dart`) — the same code path
// `oka run <target>` delegates to (ADR-0015).
import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> runFixture(final List<String> args) =>
      Process.run(
        'dart',
        ['run', 'test/fixtures/adr0014_plan_print_entrypoint.dart', ...args],
        workingDirectory: Directory.current.path,
      );

  group('dry-run dispatch prints the publish plan (ADR-0014 law)', () {
    test('oka run publish-fixture prints the plan lines', () async {
      final result = await runFixture(['--oka-run-target', 'publish-fixture']);
      expect(result.exitCode, 0, reason: 'stdout: ${result.stdout}\n'
          'stderr: ${result.stderr}');
      final out = result.stdout as String;
      expect(out, contains('📋 Publish plan for "publish-fixture":'));
      expect(out, contains('endpoint: Fixture Publisher API'));
      expect(out, contains('track: internal'));
      expect(out, contains('artifact: fixture-artifact'));
      expect(out, contains('dry run — nothing was uploaded'));
    });

    test('the plan names the real oka AAB output path as the artifact',
        () async {
      // The staged artifact follows oka's AAB layout (<buildDir>/aab/…).
      final result = await runFixture(['--oka-run-target', 'publish-fixture']);
      expect(result.stdout, contains('fixture.aab'));
    });
  });

  group('build dispatch output is unchanged', () {
    test('a platform build dispatch prints the apk_path line, no plan',
        () async {
      final result = await runFixture(const ['--platform', 'android']);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      final out = result.stdout as String;
      expect(out, contains('Build complete'));
      expect(out, isNot(contains('Publish plan')));
      expect(out, isNot(contains('dry run — nothing was uploaded')));
    });

    test('a non-publish target dispatch prints no plan header', () async {
      final result = await runFixture([
        '--oka-run-target',
        'echo',
      ]);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout, isNot(contains('Publish plan')));
    });
  });
}
