import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fixture;
  late String pkgA;
  late String pkgB;

  setUp(() {
    fixture = Fixture.create();
    pkgA = fixture.path('pkgs/a');
    pkgB = fixture.path('pkgs/b');
    fixture.writePackageConfig({'a': 'pkgs/a', 'b': 'pkgs/b'});
  });

  tearDown(() => fixture.dispose());

  WorkspaceGraph graph() => WorkspaceGraph(
    repoRoot: fixture.root.path,
    packages: {'a': pkgA, 'b': pkgB},
  );

  test('affected suites follow transitive imports across packages', () {
    fixture
      ..write('pkgs/a/lib/core.dart', 'var x = 1;')
      ..write('pkgs/a/lib/uses_core.dart', "import 'package:a/core.dart';")
      ..write(
        'pkgs/a/test/direct_test.dart',
        "import 'package:a/uses_core.dart'; void main() {}",
      )
      ..write('pkgs/a/test/unrelated_test.dart', 'void main() {}')
      ..write(
        'pkgs/b/test/crosses_test.dart',
        "import 'package:a/core.dart'; void main() {}",
      );

    final g = graph();
    final suites = g.testSuites(pkgA) + g.testSuites(pkgB);
    expect(suites, hasLength(3));

    final affected = g.affectedSuites(['$pkgA/lib/core.dart'], suites);
    expect(
      affected,
      containsAll(<String>[
        '$pkgA/test/direct_test.dart',
        '$pkgB/test/crosses_test.dart',
      ]),
    );
    expect(affected, isNot(contains('$pkgA/test/unrelated_test.dart')));
  });

  test('neighboring package source participates in cache invalidation', () {
    final neighbor = Fixture.create();
    addTearDown(neighbor.dispose);
    final dependency = neighbor.write('lib/shared.dart', 'const value = 1;');
    final suite = fixture.write(
      'pkgs/a/test/neighbor_test.dart',
      "import 'package:neighbor/shared.dart'; void main() {}",
    );
    final g = WorkspaceGraph(
      repoRoot: fixture.root.path,
      packages: {'a': pkgA, 'neighbor': neighbor.root.path},
    );
    expect(g.closureOf(suite), contains(dependency));
    final before = hashFile(dependency);
    neighbor.write('lib/shared.dart', 'const value = 2;');
    expect(hashFile(dependency), isNot(before));
    expect(g.affectedSuites([dependency], [suite]), contains(suite));
  });

  test('same-line directives include every dependency', () {
    fixture
      ..write('pkgs/a/lib/first.dart', 'const first = 1;')
      ..write('pkgs/a/lib/second.dart', 'const second = 2;');
    final suite = fixture.write(
      'pkgs/a/test/inline_test.dart',
      "import '../lib/first.dart'; /* separator */ import '../lib/second.dart'; void main() {}",
    );
    expect(
      graph().closureOf(suite),
      containsAll(['$pkgA/lib/first.dart', '$pkgA/lib/second.dart']),
    );
  });

  test('relative imports and part files join the closure', () {
    fixture
      ..write('pkgs/a/lib/parts.dart', "part 'impl.dart';")
      ..write('pkgs/a/lib/impl.dart', 'var y = 2;')
      ..write(
        'pkgs/a/test/uses_part_test.dart',
        "import '../lib/parts.dart'; void main() {}",
      );

    final g = graph();
    expect(
      g.closureOf('$pkgA/test/uses_part_test.dart'),
      containsAll(<String>['$pkgA/lib/parts.dart', '$pkgA/lib/impl.dart']),
    );
  });

  test('every branch of a conditional import is an edge', () {
    fixture
      ..write('pkgs/a/lib/io_impl.dart', 'var io = 1;')
      ..write('pkgs/a/lib/web_impl.dart', 'var web = 1;')
      ..write(
        'pkgs/a/lib/conditional.dart',
        "import 'web_impl.dart' if (dart.library.io) 'io_impl.dart';",
      )
      ..write(
        'pkgs/a/test/conditional_test.dart',
        "import 'package:a/conditional.dart'; void main() {}",
      );

    final g = graph();
    final closure = g.closureOf('$pkgA/test/conditional_test.dart');
    expect(
      closure,
      containsAll(<String>[
        '$pkgA/lib/conditional.dart',
        '$pkgA/lib/io_impl.dart',
        '$pkgA/lib/web_impl.dart',
      ]),
    );
  });

  test('a change in a conditional branch invalidates the suite', () {
    fixture
      ..write('pkgs/a/lib/io_impl.dart', 'var io = 1;')
      ..write('pkgs/a/lib/web_impl.dart', 'var web = 1;')
      ..write(
        'pkgs/a/lib/conditional.dart',
        "import 'web_impl.dart' if (dart.library.io) 'io_impl.dart';",
      )
      ..write(
        'pkgs/a/test/conditional_test.dart',
        "import 'package:a/conditional.dart'; void main() {}",
      );

    final g = graph();
    final suites = g.testSuites(pkgA);
    expect(
      g.affectedSuites(['$pkgA/lib/web_impl.dart'], suites),
      contains('$pkgA/test/conditional_test.dart'),
    );
  });

  test('sdk and unresolved dependencies stop traversal, never error', () {
    fixture.write('pkgs/a/test/external_test.dart', '''
import 'dart:async';
import 'package:test/test.dart';
import 'package:missing_pkg/nowhere.dart';
void main() {}
''');
    final g = graph();
    expect(g.closureOf('$pkgA/test/external_test.dart'), hasLength(1));
  });

  test('only imported native assets require SDK hook handling', () {
    fixture
      ..write('pkgs/b/hook/build.dart', 'void main() {}')
      ..write('pkgs/b/lib/native.dart', "import 'dart:ffi';")
      ..write('pkgs/a/test/pure_test.dart', 'void main() {}')
      ..write('pkgs/a/test/ffi_test.dart', "import 'dart:ffi';")
      ..write(
        'pkgs/a/test/native_test.dart',
        "import 'package:b/native.dart';",
      );
    expect(graph().reachesNativeAssets('$pkgA/test/pure_test.dart'), false);
    expect(graph().reachesNativeAssets('$pkgA/test/ffi_test.dart'), true);
    expect(graph().reachesNativeAssets('$pkgA/test/native_test.dart'), true);
  });

  test('a quoted word inside a comment is not an edge', () {
    fixture
      ..write('pkgs/a/lib/real.dart', 'var real = 1;')
      ..write('pkgs/a/lib/liar.dart', 'var liar = 2;')
      ..write(
        'pkgs/a/lib/user.dart',
        "import 'real.dart';\n// import 'liar.dart';\n"
            "/* import 'liar.dart'; */",
      )
      ..write(
        'pkgs/a/test/user_test.dart',
        "import 'package:a/user.dart'; void main() {}",
      );

    final g = graph();
    final closure = g.closureOf('$pkgA/test/user_test.dart');
    expect(closure, contains('$pkgA/lib/real.dart'));
    expect(closure, isNot(contains('$pkgA/lib/liar.dart')));
  });

  test('load resolves workspace package_config rootUri forms', () async {
    fixture.write('pkgs/a/lib/x.dart', '');
    final g = await WorkspaceGraph.load(fixture.root.path);
    expect(g.closureOf('$pkgA/lib/x.dart'), ['$pkgA/lib/x.dart']);
    expect(g.packageRoot('a'), pkgA);
    expect(g.packageRoot('missing'), isNull);
  });

  test('flutter suites are recognised through their closure', () {
    fixture
      ..write(
        'pkgs/a/lib/widget_helpers.dart',
        "import 'package:flutter_test/flutter_test.dart';",
      )
      ..write(
        'pkgs/a/test/widget_test.dart',
        "import 'package:a/widget_helpers.dart'; void main() {}",
      )
      ..write(
        'pkgs/a/test/pure_test.dart',
        "import 'package:test/test.dart'; void main() {}",
      );

    final g = graph();
    expect(g.reachesFlutter('$pkgA/test/widget_test.dart'), isTrue);
    expect(g.reachesFlutter('$pkgA/test/pure_test.dart'), isFalse);
  });
}
