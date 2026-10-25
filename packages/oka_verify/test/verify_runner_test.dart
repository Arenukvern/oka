import 'dart:io';

import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

final class _FakeKernelBuilder implements SuiteKernelBuilder {
  _FakeKernelBuilder({this.failure});

  final RebuildFailure? failure;
  final List<String> requested = <String>[];

  @override
  String get precompiledDir => '/tmp/oka-verify-fake/precompiled';

  @override
  Future<KernelRebuildResult> ensureKernels(
    List<String> suites, {
    void Function(String suite)? onRebuilt,
    void Function(String suite, String output)? onFailed,
  }) async {
    requested.addAll(suites);
    final fail = failure;
    if (fail != null) {
      onFailed?.call(fail.suite, fail.output);
      return KernelRebuildResult(
        rebuilt: const <String>[],
        stale: suites,
        cacheHits: 0,
        rebuildMs: 1,
        failure: fail,
      );
    }
    final rebuild = onRebuilt;
    if (rebuild != null) suites.forEach(rebuild);    return KernelRebuildResult(
      rebuilt: suites,
      stale: suites,
      cacheHits: 0,
      rebuildMs: 1,
    );
  }
}

final class _FakeTestRunner implements SuiteTestRunner {
  _FakeTestRunner({this.exitCode = 0});

  final int exitCode;
  final List<String> requested = <String>[];

  @override
  Future<TestRunOutcome> runSuites(
    List<String> suites, {
    required String workingDirectory,
    required String precompiledDir,
  }) async {
    requested.addAll(suites);
    return TestRunOutcome(
      exitCode: exitCode,
      duration: const Duration(milliseconds: 2),
    );
  }
}

void main() {
  late Fixture fixture;

  setUp(() {
    fixture = Fixture.create()
      ..writePackageConfig({'a': 'pkgs/a'})
      ..write('pkgs/a/lib/core.dart', 'var core = 1;')
      ..write(
        'pkgs/a/test/core_test.dart',
        "import 'package:a/core.dart'; void main() {}",
      )
      ..write(
        'pkgs/a/test/other_test.dart',
        "import 'package:test/test.dart'; void main() {}",
      );
  });

  tearDown(() => fixture.dispose());

  VerifyOptions options({List<String>? changed, bool noRun = false}) =>
      VerifyOptions(
        repoRoot: fixture.root.path,
        packageName: 'a',
        changed: changed ?? const <String>[],
        noRun: noRun,
      );

  test('a green run writes a receipt and exits zero', () async {
    final builder = _FakeKernelBuilder();
    final runner = _FakeTestRunner();
    final result = await OkaVerify(
      kernelBuilder: builder,
      testRunner: runner,
    ).run(options());

    expect(result.exitCode, 0);
    expect(result.pass, isTrue);
    expect(result.error, isNull);
    expect(runner.requested, hasLength(2));
    expect(File(result.receiptPath).existsSync(), isTrue);
    expect(result.receipt.pass, isTrue);
    expect(result.receipt.selectedSuites, hasLength(2));
  });

  test('a failing suite fails the run and the receipt', () async {
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: _FakeTestRunner(exitCode: 1),
    ).run(options());

    expect(result.exitCode, 1);
    expect(result.receipt.pass, isFalse);
  });

  test('a kernel failure stops the run and names the failing suite', () async {
    final runner = _FakeTestRunner();
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(
        failure: RebuildFailure(
          suite: '/w/pkgs/a/test/core_test.dart',
          output: 'Error: something broke',
        ),
      ),
      testRunner: runner,
    ).run(options());

    expect(result.exitCode, 65);
    expect(result.receipt.pass, isFalse);
    expect(result.receipt.rebuildError, contains('something broke'));
    expect(runner.requested, isEmpty);
  });

  test('--no-run builds the kernels without running the suites', () async {
    final runner = _FakeTestRunner();
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: runner,
    ).run(options(noRun: true));

    expect(result.exitCode, 0);
    expect(runner.requested, isEmpty);
    expect(result.receipt.rebuiltSuites, hasLength(2));
  });

  test('a change selects only the suites it reaches', () async {
    final runner = _FakeTestRunner();
    await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: runner,
    ).run(
      options(changed: <String>[fixture.path('pkgs/a/lib/core.dart')]),
    );

    expect(runner.requested, <String>[fixture.path('pkgs/a/test/core_test.dart')]);
  });

  test('a relative changed path is resolved against the workspace root',
      () async {
    final runner = _FakeTestRunner();
    await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: runner,
    ).run(
      options(changed: <String>['pkgs/a/lib/core.dart']),
    );

    expect(
      runner.requested,
      <String>[fixture.path('pkgs/a/test/core_test.dart')],
    );
  });

  test('unknown coverage widens the run to every suite', () async {
    final runner = _FakeTestRunner();
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: runner,
    ).run(
      options(changed: <String>[fixture.path('pkgs/a/pubspec.yaml')]),
    );

    expect(runner.requested, hasLength(2));
    expect(result.broadenReason, contains('pubspec.yaml'));
    expect(result.receipt.broadenReason, isNotNull);
    expect(result.receipt.uncoveredChanges, hasLength(1));
  });

  test('a widget suite is refused, not run', () async {
    fixture.write(
      'pkgs/a/test/widget_test.dart',
      "import 'package:flutter_test/flutter_test.dart'; void main() {}",
    );
    final runner = _FakeTestRunner();
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: runner,
    ).run(options());

    expect(
      result.refusedFlutterSuites,
      contains(fixture.path('pkgs/a/test/widget_test.dart')),
    );
    expect(
      runner.requested,
      isNot(contains(fixture.path('pkgs/a/test/widget_test.dart'))),
    );
    expect(result.receipt.refusedFlutterSuites, hasLength(1));
  });

  test('a package with only widget suites reports the boundary', () async {
    fixture.write(
      'pkgs/a/test/widget_test.dart',
      "import 'package:flutter_test/flutter_test.dart'; void main() {}",
    );
    File(fixture.path('pkgs/a/test/core_test.dart')).deleteSync();
    File(fixture.path('pkgs/a/test/other_test.dart')).deleteSync();
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: _FakeTestRunner(),
    ).run(options());

    expect(result.exitCode, 66);
    expect(result.error, contains('flutter test'));
  });

  test('an unknown package is an error, not a crash', () async {
    final result = await OkaVerify(
      kernelBuilder: _FakeKernelBuilder(),
      testRunner: _FakeTestRunner(),
    ).run(
      VerifyOptions(
        repoRoot: fixture.root.path,
        packageName: 'nope',
        changed: const <String>[],
      ),
    );

    expect(result.exitCode, 66);
    expect(result.error, contains('unknown package'));
  });
}
