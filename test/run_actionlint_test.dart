import 'dart:io';

import 'package:test/test.dart';

void main() {
  final repo = Directory.current.path;
  late Directory fixture;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('oka_actionlint_');
    File('${fixture.path}/tool/contracts/run_actionlint.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        File('$repo/tool/contracts/run_actionlint.sh').readAsStringSync(),
      );
    Directory('${fixture.path}/.github/workflows').createSync(recursive: true);
    File('${fixture.path}/.github/workflows/ci.yml').writeAsStringSync(
      'name: CI\non: push\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n',
    );
    Process.runSync(
      'chmod',
      ['+x', '${fixture.path}/tool/contracts/run_actionlint.sh'],
    );
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  test('unsupported platform skips with exit 0', () {
    final result = Process.runSync(
      'bash',
      ['tool/contracts/run_actionlint.sh'],
      workingDirectory: fixture.path,
      environment: {
        'OKA_ACTIONLINT_PLATFORM': 'freebsd_386',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      '${result.stdout}${result.stderr}',
      contains('skipping'),
    );
  });

  test('linux amd64 runs actionlint when binary available', () {
    final result = Process.runSync(
      'bash',
      ['tool/contracts/run_actionlint.sh'],
      workingDirectory: fixture.path,
      environment: {
        'OKA_ACTIONLINT_PLATFORM': 'linux_amd64',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}${result.stderr}', contains('run_actionlint: OK'));
  });
}