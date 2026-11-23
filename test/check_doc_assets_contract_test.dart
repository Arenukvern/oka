import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('check_doc_assets.dart exits 0', () {
    final root = Directory.current.path;
    final result = Process.runSync(
      'dart',
      ['tool/contracts/check_doc_assets.dart'],
      environment: {'OKA_ROOT': root},
    );
    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}${result.stderr}',
    );
  });
}
