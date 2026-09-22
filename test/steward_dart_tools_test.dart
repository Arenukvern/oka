import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/benchmarks/build_benchmarks.dart' as benchmarks;
import '../tool/contracts/check_docs_drift.dart' as docs_drift;

void main() {
  group('docs sidebar drift', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('oka-docs-drift-');
      Directory('${root.path}/docs/guides').createSync(recursive: true);
      File('${root.path}/docs.json').writeAsStringSync(
        jsonEncode({
          'sidebar': [
            {
              'pages': [
                {'href': '/guides/build'},
                {'href': 'https://example.com/reference'},
              ],
            },
          ],
        }),
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('accepts extensionless routes when the mdx file exists', () {
      File('${root.path}/docs/guides/build.mdx').writeAsStringSync('guide');

      expect(docs_drift.missingSidebarEntries(root), isEmpty);
    });

    test('reports extensionless routes whose mdx file is missing', () {
      expect(docs_drift.missingSidebarEntries(root), ['/guides/build']);
    });
  });

  group('benchmark helpers', () {
    test('formats elapsed seconds to two decimal places', () {
      expect(
        benchmarks.formatSeconds(const Duration(milliseconds: 1234)),
        '1.23',
      );
    });

    test('extracts Flutter version and preserves summary schema', () {
      expect(
        benchmarks.flutterFrameworkVersion('{"frameworkVersion":"3.35.0"}'),
        '3.35.0',
      );
      final summary = benchmarks.buildSummary(
        timestamp: '2026-09-15T120000Z',
        runner: 'dart-run',
        cold: true,
        results: {'explain': 1.25},
        okaVersion: '0.2.0',
        okaCommit: 'abc1234',
        flutterVersion: '3.35.0',
        osName: 'Darwin arm64',
      );

      expect(summary['schema'], 'oka/build-benchmarks/v1');
      expect(summary['cold'], isTrue);
      expect(summary['results_seconds'], {'explain': 1.25});
    });

    test('returns unknown for malformed Flutter machine output', () {
      expect(benchmarks.flutterFrameworkVersion('[]'), 'unknown');
      expect(benchmarks.flutterFrameworkVersion('not-json'), 'unknown');
    });

    test(
      'cold benchmark rejects an existing backup without moving cache',
      () async {
        final root = Directory.systemTemp.createTempSync('oka-benchmark-');
        addTearDown(() => root.deleteSync(recursive: true));
        final project = Directory('${root.path}/example')..createSync();
        File(
          '${project.path}/pubspec.yaml',
        ).writeAsStringSync('name: fixture\n');
        final cache = Directory('${project.path}/.oka_cache')..createSync();
        File('${cache.path}/marker').writeAsStringSync('original');
        final backup = Directory('${project.path}/.oka_cache.bench-backup')
          ..createSync();
        File('${backup.path}/marker').writeAsStringSync('existing backup');

        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            File('tool/benchmarks/build_benchmarks.dart').absolute.path,
            project.path,
            '--cold',
          ],
          environment: {...Platform.environment, 'OKA_ROOT': root.path},
        );

        expect(result.exitCode, 1);
        expect(File('${cache.path}/marker').readAsStringSync(), 'original');
        expect(
          File('${backup.path}/marker').readAsStringSync(),
          'existing backup',
        );
      },
    );

    test(
      'forwards interruption and restores cache after child exits',
      () async {
        if (Platform.isWindows) return;

        final root = Directory.systemTemp.createTempSync('oka-benchmark-');
        addTearDown(() => root.deleteSync(recursive: true));
        final project = Directory('${root.path}/example')..createSync();
        File(
          '${project.path}/pubspec.yaml',
        ).writeAsStringSync('name: fixture\n');
        final cache = Directory('${project.path}/.oka_cache')..createSync();
        File('${cache.path}/marker').writeAsStringSync('original');
        final started = File('${root.path}/child-started');
        final interrupted = File('${root.path}/child-interrupted');

        final bin = Directory('${root.path}/bin')..createSync();
        final fakeOka = File('${bin.path}/oka')
          ..writeAsStringSync(
            [
              '#!/usr/bin/env bash',
              r'if [[ "${1:-}" == "--version" ]]; then',
              '  echo "Oka version 0.2.0"',
              '  exit 0',
              'fi',
              'touch "${started.path}"',
              'trap \'touch "${interrupted.path}"; exit 130\' INT TERM',
              'while true; do sleep 0.05; done',
              '',
            ].join('\n'),
          );
        await Process.run('chmod', ['+x', fakeOka.path]);

        final benchmark = await Process.start(
          Platform.resolvedExecutable,
          [
            File('tool/benchmarks/build_benchmarks.dart').absolute.path,
            project.path,
            '--cold',
          ],
          environment: {
            ...Platform.environment,
            'OKA_ROOT': root.path,
            'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
          },
        );
        addTearDown(() => benchmark.kill(ProcessSignal.sigkill));

        await _waitForFile(started);
        expect(benchmark.kill(ProcessSignal.sigint), isTrue);
        final exitCode = await benchmark.exitCode.timeout(
          const Duration(seconds: 5),
        );

        expect(exitCode, 130);
        expect(interrupted.existsSync(), isTrue);
        expect(File('${cache.path}/marker').readAsStringSync(), 'original');
        expect(
          Directory('${project.path}/.oka_cache.bench-backup').existsSync(),
          isFalse,
        );
      },
    );

    test('cold benchmark restores cache after a failed step', () async {
      final root = Directory.systemTemp.createTempSync('oka-benchmark-');
      addTearDown(() => root.deleteSync(recursive: true));
      final project = Directory('${root.path}/example')..createSync();
      File('${project.path}/pubspec.yaml').writeAsStringSync('name: fixture\n');
      final cache = Directory('${project.path}/.oka_cache')..createSync();
      File('${cache.path}/marker').writeAsStringSync('original');

      final bin = Directory('${root.path}/bin')..createSync();
      final fakeOka = File('${bin.path}/oka')
        ..writeAsStringSync(
          [
            '#!/usr/bin/env bash',
            r'if [[ "${1:-}" == "--version" ]]; then',
            '  echo "Oka version 0.2.0"',
            '  exit 0',
            'fi',
            r'if [[ "${1:-}" == "build" ]]; then',
            '  exit 7',
            'fi',
            'exit 0',
            '',
          ].join('\n'),
        );
      await Process.run('chmod', ['+x', fakeOka.path]);

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          File('tool/benchmarks/build_benchmarks.dart').absolute.path,
          project.path,
          '--cold',
        ],
        environment: {
          ...Platform.environment,
          'OKA_ROOT': root.path,
          'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );

      expect(result.exitCode, 1);
      expect(File('${cache.path}/marker').readAsStringSync(), 'original');
      expect(
        Directory('${project.path}/.oka_cache.bench-backup').existsSync(),
        isFalse,
      );
    });
  });
}

Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
