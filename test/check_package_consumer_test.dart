import 'dart:io';

import 'package:test/test.dart';

void main() {
  final repo = Directory.current.path;
  late Directory fixture;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('oka_check_consumer_');
    File('${fixture.path}/VERSION').writeAsStringSync('0.2.0\n');
    File('${fixture.path}/tool/ci/check_package_consumer.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        File('$repo/tool/ci/check_package_consumer.sh').readAsStringSync(),
      );
    File('${fixture.path}/tool/release/train.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        File('$repo/tool/release/train.dart').readAsStringSync(),
      );
    for (final package in ['oka', 'oka_core']) {
      final dir = Directory('${fixture.path}/packages/$package');
      dir.createSync(recursive: true);
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $package\n');
      File('${dir.path}/lib/$package.dart').writeAsStringSync('library;\n');
    }
    Process.runSync(
      'chmod',
      ['+x', '${fixture.path}/tool/ci/check_package_consumer.sh'],
    );
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  test('hosted mode retries only when pub get cannot resolve train version', () {
    final fake = _installFakeDart(fixture);
    final result = _run(
      fixture,
      fake,
      mode: '--hosted',
      extra: {
        'OKA_HOSTED_CONSUMER_RETRY_SECONDS': '1',
        'OKA_HOSTED_CONSUMER_TIMEOUT_SECONDS': '5',
        'OKA_FAKE_PUB_GET_MODE': 'resolve',
      },
    );
    expect(result.exitCode, 0, reason: _out(result));
    expect(fake.attempts, greaterThan(1));
    expect(fake.analyzeRuns, greaterThanOrEqualTo(1));
  });

  test('hosted mode fails fast when dart analyze fails after pub get', () {
    final fake = _installFakeDart(fixture);
    final result = _run(
      fixture,
      fake,
      mode: '--hosted',
      extra: {
        'OKA_HOSTED_CONSUMER_RETRY_SECONDS': '1',
        'OKA_HOSTED_CONSUMER_TIMEOUT_SECONDS': '30',
        'OKA_FAKE_PUB_GET_MODE': 'ok',
        'OKA_FAKE_ANALYZE_FAIL': '1',
      },
    );
    expect(result.exitCode, 1, reason: _out(result));
    expect(fake.attempts, 1);
    expect(fake.analyzeRuns, 1);
  });
}

class _FakeDart {
  _FakeDart(this.bin);

  final String bin;
  int attempts = 0;
  int analyzeRuns = 0;
}

_FakeDart _installFakeDart(Directory fixture) {
  final bin = '${fixture.path}/fake-bin';
  Directory(bin).createSync();
  File('$bin/dart').writeAsStringSync(r'''#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == *train.dart ]]; then
  exec "$OKA_REAL_DART" "$@"
fi
if [[ "${1:-}" == "pub" && "${2:-}" == "get" ]]; then
  echo 1 >> "$OKA_CONSUMER_ATTEMPT_LOG"
  if [[ "$OKA_FAKE_PUB_GET_MODE" == "resolve" ]]; then
    attempts=$(wc -l < "$OKA_CONSUMER_ATTEMPT_LOG" | tr -d ' ')
    if [[ "$attempts" -lt 3 ]]; then
      echo "version solving failed: oka 0.2.0 not found on pub.dev" >&2
      exit 1
    fi
    exit 0
  fi
  exit 0
fi
if [[ "${1:-}" == "analyze" ]]; then
  echo analyze >> "$OKA_CONSUMER_ANALYZE_LOG"
  [[ "${OKA_FAKE_ANALYZE_FAIL:-}" != "1" ]]
  exit $?
fi
if [[ "${1:-}" == "run" ]]; then
  exit 0
fi
echo "unexpected dart: $*" >&2
exit 2
''');
  Process.runSync('chmod', ['+x', '$bin/dart']);
  File('${fixture.path}/attempts.log').writeAsStringSync('');
  File('${fixture.path}/analyze.log').writeAsStringSync('');
  return _FakeDart(bin);
}

ProcessResult _run(
  Directory fixture,
  _FakeDart fake, {
  String mode = '',
  Map<String, String> extra = const {},
}) {
  final result = Process.runSync(
    'bash',
    ['tool/ci/check_package_consumer.sh', if (mode.isNotEmpty) mode],
    workingDirectory: fixture.path,
    environment: {
      'OKA_ROOT': fixture.path,
      'PATH': '${fake.bin}:${Platform.environment['PATH']}',
      'OKA_REAL_DART': Process.runSync('sh', ['-c', 'command -v dart']).stdout
          .toString()
          .trim(),
      'OKA_CONSUMER_ATTEMPT_LOG': '${fixture.path}/attempts.log',
      'OKA_CONSUMER_ANALYZE_LOG': '${fixture.path}/analyze.log',
      ...extra,
    },
  );
  fake.attempts = File('${fixture.path}/attempts.log').readAsLinesSync().length;
  fake.analyzeRuns = File('${fixture.path}/analyze.log')
      .readAsLinesSync()
      .where((line) => line == 'analyze')
      .length;
  return result;
}

String _out(ProcessResult result) => '${result.stdout}\n${result.stderr}';