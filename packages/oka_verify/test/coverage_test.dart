import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fixture;
  late String pkgA;

  setUp(() {
    fixture = Fixture.create();
    pkgA = fixture.path('pkgs/a');
    fixture.writePackageConfig({'a': 'pkgs/a'});
  });

  tearDown(() => fixture.dispose());

  WorkspaceGraph graph() => WorkspaceGraph(
        repoRoot: fixture.root.path,
        packages: {'a': pkgA},
      );

  test('a dependency descriptor has unknown coverage', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[fixture.path('pkgs/a/pubspec.yaml')],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.dartChanges, isEmpty);
    expect(analysis.uncovered, hasLength(1));
    expect(analysis.broadenReason, contains('pubspec.yaml'));
  });

  test('a lockfile and a package config have unknown coverage', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[
        fixture.path('pubspec.lock'),
        fixture.path('.dart_tool/package_config.json'),
      ],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.uncovered, hasLength(2));
  });

  test('a non-dart file inside the package has unknown coverage', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[fixture.path('pkgs/a/test/fixtures/data.json')],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.dartChanges, isEmpty);
    expect(analysis.uncovered, hasLength(1));
  });

  test('a non-dart file outside the package is not the package concern', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[fixture.path('docs/readme.md')],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.dartChanges, isEmpty);
    expect(analysis.uncovered, isEmpty);
    expect(analysis.broadenReason, isNull);
  });

  test('a dart file outside every known package has unknown coverage', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[fixture.path('tool/script.dart')],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.dartChanges, isEmpty);
    expect(analysis.uncovered, hasLength(1));
  });

  test('a dart file inside a known package is graph-attributable', () {
    final analysis = analyzeCoverage(
      changedFiles: <String>[fixture.path('pkgs/a/lib/core.dart')],
      graph: graph(),
      packageRoot: pkgA,
    );
    expect(analysis.dartChanges, hasLength(1));
    expect(analysis.uncovered, isEmpty);
    expect(analysis.broadenReason, isNull);
  });
}
