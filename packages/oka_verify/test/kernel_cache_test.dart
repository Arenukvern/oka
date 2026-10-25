import 'dart:io';

import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fixture;
  late String suite;

  setUp(() {
    fixture = Fixture.create()
      ..writePackageConfig({'a': 'pkgs/a'})
      ..write('pkgs/a/lib/core.dart', 'var core = 1;');
    suite = fixture.write(
      'pkgs/a/test/core_test.dart',
      "import 'package:a/core.dart'; void main() {}",
    );
  });

  tearDown(() => fixture.dispose());

  String packageA() => fixture.path('pkgs/a');

  KernelCache cache({CacheKeyContext? injectedContext}) => KernelCache(
    repoRoot: fixture.root.path,
    graph: WorkspaceGraph(
      repoRoot: fixture.root.path,
      packages: {'a': packageA()},
    ),
    packageRoot: packageA(),
    packageName: 'a',
    injectedContext: injectedContext,
  );

  test('the key of a suite is stable across calls', () {
    expect(cache().suiteKey(suite), cache().suiteKey(suite));
  });

  test('a change in the closure invalidates the suite kernel', () {
    final before = cache().suiteKey(suite);
    fixture.write('pkgs/a/lib/core.dart', 'var core = 1000000;');
    final after = cache().suiteKey(suite);
    expect(after, isNot(before));
  });

  test('same-size content edits invalidate even with preserved mtime', () {
    final file = File(fixture.path('pkgs/a/lib/core.dart'));
    final timestamp = file.lastModifiedSync();
    final c = cache();
    final before = c.suiteKey(suite);
    c.saveFileHashes();
    file
      ..writeAsStringSync('var core = 2;')
      ..setLastModifiedSync(timestamp);
    expect(c.suiteKey(suite), isNot(before));
    expect(cache().suiteKey(suite), isNot(before));
  });

  test('new conditional targets invalidate their missing-file key', () {
    fixture
      ..write(
        'pkgs/a/lib/core.dart',
        "export 'future.dart' if (dart.library.io) 'present.dart';",
      )
      ..write('pkgs/a/lib/present.dart', 'const value = 1;');
    final c = cache();
    final before = c.suiteKey(suite);
    fixture.write('pkgs/a/lib/future.dart', 'const value = 2;');
    expect(c.suiteKey(suite), isNot(before));
  });

  test('a change outside the closure keeps the suite kernel valid', () {
    final before = cache().suiteKey(suite);
    fixture.write('pkgs/a/lib/other.dart', 'var other = 1;');
    expect(cache().suiteKey(suite), before);
  });

  test('a change in the package configuration invalidates the kernel', () {
    final before = cache().suiteKey(suite);
    fixture.writePackageConfig({'a': 'pkgs/a', 'c': 'pkgs/c'});
    expect(cache().suiteKey(suite), isNot(before));
  });

  test('the SDK version is part of the key', () {
    final withSdk = cache(
      injectedContext: const CacheKeyContext(
        sdkVersion: '9.9.9',
        packageConfigHash: 'x',
        contractVersion: '1',
      ),
    );
    expect(withSdk.suiteKey(suite), isNot(cache().suiteKey(suite)));
  });

  test('the dill path follows the precompiled contract', () {
    final c = cache();
    expect(
      c.dillPath(suite),
      endsWith('test/core_test.dart.vm_test.vm.app.dill'),
    );
    expect(c.precompiledDir, contains('.dart_tool/oka_verify/a/precompiled'));
  });
}
