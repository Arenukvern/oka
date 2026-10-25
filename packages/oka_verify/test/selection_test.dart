import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

void main() {
  const all = <String>[
    '/w/pkgs/a/test/alpha_test.dart',
    '/w/pkgs/a/test/beta_test.dart',
    '/w/pkgs/a/test/gamma_test.dart',
  ];
  const affected = <String>{'/w/pkgs/a/test/beta_test.dart'};

  test('the default selects the suites a change reaches', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: affected,
      ),
    );
    expect(selection.suites, ['/w/pkgs/a/test/beta_test.dart']);
    expect(selection.broadened, isFalse);
  });

  test('a change that reaches nothing selects everything', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: <String>{},
      ),
    );
    expect(selection.suites, all);
  });

  test('--all selects every suite', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: affected,
        all: true,
      ),
    );
    expect(selection.suites, all);
  });

  test('--only narrows by substring and wins over the affected set', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: affected,
        onlyFilters: <String>['gamma'],
      ),
    );
    expect(selection.suites, ['/w/pkgs/a/test/gamma_test.dart']);
  });

  test('--only that matches nothing is an error, not an empty run', () {
    expect(
      () => selectSuites(
        const SelectionRequest(
          allSuites: all,
          affectedSuites: affected,
          onlyFilters: <String>['nothing-matches-this'],
        ),
      ),
      throwsA(isA<SelectionError>()),
    );
  });

  test('unknown coverage widens the run to every suite', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: affected,
        broadenReason: 'unknown dependency coverage: /w/pubspec.yaml',
      ),
    );
    expect(selection.suites, all);
    expect(selection.broadened, isTrue);
    expect(selection.broadenReason, contains('pubspec.yaml'));
  });

  test('an explicit --only stays authoritative over a widened run', () {
    final selection = selectSuites(
      const SelectionRequest(
        allSuites: all,
        affectedSuites: affected,
        onlyFilters: <String>['alpha'],
        broadenReason: 'unknown dependency coverage: /w/pubspec.yaml',
      ),
    );
    expect(selection.suites, ['/w/pkgs/a/test/alpha_test.dart']);
  });
}
