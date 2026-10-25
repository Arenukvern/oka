import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

void main() {
  test('bootstrap hands the suite main to the test_core VM bootstrap', () {
    final source = suiteBootstrapSource(
      suitePath: '/r/pkgs/a/test/core_test.dart',
      bootDir: '/r/.dart_tool/oka_verify/a/boot',
    );
    expect(
      source,
      contains("import '../../../../pkgs/a/test/core_test.dart' as suite;"),
    );
    expect(
      source,
      contains('internalBootstrapVmTest(() => suite.main, sendPort);'),
    );
    expect(source, contains('void main(List<String> args, SendPort sendPort)'));
  });

  test('relative import walks up without escaping', () {
    expect(
      relativeImport('/r/pkgs/a/test/x_test.dart', '/r/.dart_tool/c'),
      '../../pkgs/a/test/x_test.dart',
    );
    expect(
      relativeImport('/r/.dart_tool/c/sibling.dart', '/r/.dart_tool/c'),
      './sibling.dart',
    );
  });

  test('the contract version is a stable, named value', () {
    expect(bootstrapContractVersion, isNotEmpty);
  });
}
