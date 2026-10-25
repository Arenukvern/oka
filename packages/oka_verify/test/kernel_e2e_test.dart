import 'dart:async';
import 'dart:io';

import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// The end-to-end proof of the lane: a real suite is compiled into a
/// kernel by the content-keyed cache, the cache is a hit on the second
/// pass, and the kernel runs through `dart test --precompiled`.
///
/// This is the one test that starts a compiler and a test runner, so both
/// are bounded by an explicit budget.
void main() {
  late Fixture fixture;

  setUp(() {
    fixture = Fixture.create();
  });

  tearDown(() => fixture.dispose());

  test('warm compilation enforces its declared budget', () async {
    final packageRoot = fixture.path('pkgs/a');
    final suite = fixture.write('pkgs/a/test/core_test.dart', 'void main() {}');
    fixture.writeWorkspacePackageConfig('a', packageRoot);
    final cache = KernelCache(
      repoRoot: fixture.root.path,
      graph: await WorkspaceGraph.load(fixture.root.path),
      packageRoot: packageRoot,
      packageName: 'a',
      budget: const VerifyBudget(compileTimeout: Duration(microseconds: 1)),
    );
    final result = await cache.ensureKernels([suite]);
    expect(result.ok, isFalse);
    expect(result.failure!.output, contains('configured budget'));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a source edit during compilation refuses cache publication', () async {
    final packageRoot = fixture.path('pkgs/a');
    fixture
      ..write('pkgs/a/lib/core.dart', 'const answer = 42;')
      ..write(
        'pkgs/a/test/core_test.dart',
        "import 'package:a/core.dart'; void main() { print(answer); }",
      )
      ..writeWorkspacePackageConfig('a', packageRoot);
    final suite = fixture.path('pkgs/a/test/core_test.dart');
    final cache = KernelCache(
      repoRoot: fixture.root.path,
      graph: await WorkspaceGraph.load(fixture.root.path),
      packageRoot: packageRoot,
      packageName: 'a',
    );
    var edited = false;
    // The bootstrap is written after selection and before the compiler
    // reads source. Change a real input during that async compilation.
    final edit = Timer.periodic(const Duration(milliseconds: 5), (timer) {
      if (!File('${cache.bootDir}/test/core_test.dart.boot.dart')
          .existsSync()) {
        return;
      }
      fixture.write('pkgs/a/lib/core.dart', 'const answer = 43;');
      edited = true;
      timer.cancel();
    });
    addTearDown(edit.cancel);
    final result = await cache.ensureKernels([suite]);
    expect(edited, isTrue);
    expect(result.ok, isFalse);
    expect(result.failure!.output, contains('source_changed_during_compile'));
    expect(File(cache.dillPath(suite)).existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a suite kernel compiles, caches and runs', () async {
    final packageRoot = fixture.path('pkgs/a');
    fixture
      ..write(
        'pkgs/a/pubspec.yaml',
        'name: a\nenvironment:\n  sdk: ^3.13.0\n'
            'dev_dependencies:\n  test: ^1.25.0\n',
      )
      ..write('pkgs/a/lib/core.dart', 'int answer() => 42;\n')
      ..write(
        'pkgs/a/test/core_test.dart',
        "import 'package:a/core.dart';\n"
            "import 'package:test/test.dart';\n"
            'void main() {\n'
            "  test('answers', () => expect(answer(), 42));\n"
            '}\n',
      )
      ..writeWorkspacePackageConfig('a', packageRoot);

    final graph = await WorkspaceGraph.load(fixture.root.path);
    final suite = fixture.path('pkgs/a/test/core_test.dart');
    final cache = KernelCache(
      repoRoot: fixture.root.path,
      graph: graph,
      packageRoot: packageRoot,
      packageName: 'a',
      budget: const VerifyBudget(
        compileTimeout: Duration(minutes: 3),
        runTimeout: Duration(minutes: 2),
      ),
    );

    final first = await cache.ensureKernels([suite]);
    expect(first.ok, isTrue, reason: first.failure?.output);
    expect(first.rebuilt, contains(suite));
    expect(File(cache.dillPath(suite)).existsSync(), isTrue);

    final second = await cache.ensureKernels([suite]);
    expect(second.ok, isTrue, reason: second.failure?.output);
    expect(second.cacheHits, 1);
    expect(second.rebuilt, isEmpty);

    final outcome =
        await const DartTestRunner(
          budget: VerifyBudget(runTimeout: Duration(minutes: 2)),
        ).runSuites(
          [suite],
          workingDirectory: packageRoot,
          precompiledDir: cache.precompiledDir,
        );
    expect(outcome.exitCode, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a broken suite fails loudly instead of skipping', () async {
    final packageRoot = fixture.path('pkgs/a');
    fixture
      ..write(
        'pkgs/a/pubspec.yaml',
        'name: a\nenvironment:\n  sdk: ^3.13.0\n'
            'dev_dependencies:\n  test: ^1.25.0\n',
      )
      ..write(
        'pkgs/a/test/broken_test.dart',
        "import 'package:test/test.dart';\n"
            'void main() {\n'
            "  test('fails', () => expect(1, 2));\n"
            '}\n',
      )
      ..writeWorkspacePackageConfig('a', packageRoot);

    final graph = await WorkspaceGraph.load(fixture.root.path);
    final suite = fixture.path('pkgs/a/test/broken_test.dart');
    final cache = KernelCache(
      repoRoot: fixture.root.path,
      graph: graph,
      packageRoot: packageRoot,
      packageName: 'a',
      budget: const VerifyBudget(
        compileTimeout: Duration(minutes: 3),
        runTimeout: Duration(minutes: 2),
      ),
    );

    final rebuild = await cache.ensureKernels([suite]);
    expect(rebuild.ok, isTrue, reason: rebuild.failure?.output);

    final outcome =
        await const DartTestRunner(
          budget: VerifyBudget(runTimeout: Duration(minutes: 2)),
        ).runSuites(
          [suite],
          workingDirectory: packageRoot,
          precompiledDir: cache.precompiledDir,
        );
    expect(outcome.exitCode, isNot(0));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
