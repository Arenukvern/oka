/// The orchestration of the oka verify lane (ADR-0048).
///
/// One run is: read the workspace → resolve the package → read the changed
/// files → decide the coverage → select the suites → refuse the widget
/// suites → build the kernels → run the suites → write the receipt.
///
/// Every step that can be a pure function is one, and every step that
/// touches the outside world sits behind an interface, so the run can be
/// exercised without a compiler, a test runner or a git repository.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'budget.dart';
import 'coverage.dart';
import 'git.dart';
import 'import_graph.dart';
import 'kernel_builder.dart';
import 'kernel_cache.dart';
import 'receipt.dart';
import 'selection.dart';
import 'test_runner.dart';

/// The options of one verify run.
final class VerifyOptions {
  const VerifyOptions({
    required this.repoRoot,
    required this.packageName,
    this.all = false,
    this.only = const <String>[],
    this.changed,
    this.noRun = false,
    this.broadenOnUncoveredChanges = true,
  });

  /// The workspace root that owns the package configuration.
  final String repoRoot;

  /// The package to verify.
  final String packageName;

  /// Verify every suite of the package.
  final bool all;

  /// Verify only the suites whose path contains one of these substrings.
  final List<String> only;

  /// The changed files, overriding the git query.
  final List<String>? changed;

  /// Build the kernels but do not run the suites.
  final bool noRun;

  /// Widen the run when a change has unknown dependency coverage.
  final bool broadenOnUncoveredChanges;
}

/// The result of one verify run.
final class VerifyResult {
  const VerifyResult({
    required this.exitCode,
    required this.receipt,
    required this.receiptPath,
    required this.selectedSuites,
    this.refusedFlutterSuites = const <String>[],
    this.broadenReason,
    this.error,
  });

  /// The exit code the CLI hands back (mirrors `dart test`).
  final int exitCode;

  /// The receipt of the run.
  final VerifyReceipt receipt;

  /// Where the receipt was written.
  final String receiptPath;

  /// The suites the run selected.
  final List<String> selectedSuites;

  /// The widget suites the lane refused.
  final List<String> refusedFlutterSuites;

  /// Why the run was widened, or null when it was not.
  final String? broadenReason;

  /// The fatal error of the run, or null when the run got as far as the
  /// receipt.
  final String? error;

  /// True when the run passed.
  bool get pass => error == null && receipt.pass;
}

/// The verify lane: the composition of selection, kernels and runner.
final class OkaVerify {
  OkaVerify({
    this.kernelBuilder,
    this.testRunner,
    this.budget = const VerifyBudget(),
    this.log,
  });

  /// The kernel builder seam; the default is the content-keyed cache.
  final SuiteKernelBuilder? kernelBuilder;

  /// The suite runner seam; the default is `dart test --precompiled`.
  final SuiteTestRunner? testRunner;

  /// The resource budget of the run.
  final VerifyBudget budget;

  /// Progress sink (the CLI writes to stderr).
  final void Function(String message)? log;

  /// Runs one verify pass and writes its receipt.
  Future<VerifyResult> run(VerifyOptions options) async {
    final graphWatch = Stopwatch()..start();
    final graph = await WorkspaceGraph.load(options.repoRoot);
    final packageRoot = graph.packageRoot(options.packageName);
    if (packageRoot == null) {
      return _fatal(
        options,
        'unknown package: ${options.packageName} '
        '(not in ${options.repoRoot}/.dart_tool/package_config.json)',
      );
    }
    final allSuites = graph.testSuites(packageRoot);
    if (allSuites.isEmpty) {
      return _fatal(options, 'no test suites under $packageRoot/test');
    }

    final changed = options.changed != null
        ? [
            for (final file in options.changed!)
              if (p.isAbsolute(file)) file else p.join(options.repoRoot, file),
          ]
        : await gitChangedFiles(options.repoRoot, timeout: budget.gitTimeout);
    final coverage = analyzeCoverage(
      changedFiles: changed,
      graph: graph,
      packageRoot: packageRoot,
    );
    final affected = graph.affectedSuites(coverage.dartChanges, allSuites);
    final broadenReason = options.broadenOnUncoveredChanges
        ? coverage.broadenReason
        : null;
    final VerifySelection selection;
    try {
      selection = selectSuites(
        SelectionRequest(
          allSuites: allSuites,
          affectedSuites: affected,
          onlyFilters: options.only,
          all: options.all,
          broadenReason: broadenReason,
        ),
      );
    } on SelectionError catch (error) {
      return _fatal(options, error.message);
    }

    // Widget suites need the `flutter_tester` shell: the lane refuses
    // them loudly instead of failing them like a broken test.
    final refused = <String>[];
    final runnable = <String>[];
    for (final suite in selection.suites) {
      if (graph.reachesFlutter(suite)) {
        refused.add(suite);
      } else {
        runnable.add(suite);
      }
    }
    for (final suite in refused) {
      _emit('refused widget suite (needs flutter_tester): $suite');
    }
    if (runnable.isEmpty) {
      return _fatal(
        options,
        'no pure-Dart suites to verify '
        '(${refused.length} widget suite(s) refused) — '
        'use `flutter test` for those',
      );
    }
    graphWatch.stop();

    final builder =
        kernelBuilder ??
        KernelCache(
          repoRoot: options.repoRoot,
          graph: graph,
          packageRoot: packageRoot,
          packageName: options.packageName,
          budget: budget,
        );
    final rebuild = await builder.ensureKernels(
      runnable,
      onRebuilt: (suite) => _emit('rebuilt $suite'),
    );

    final receiptPath =
        '${options.repoRoot}/.dart_tool/oka_verify/receipt.json';
    final revision = await gitRevision(
      options.repoRoot,
      timeout: budget.gitTimeout,
    );
    if (!rebuild.ok) {
      final receipt = VerifyReceipt(
        revision: revision,
        sdkVersion: Platform.version,
        packageName: options.packageName,
        changedFiles: changed,
        selectedSuites: runnable,
        rebuiltSuites: rebuild.rebuilt,
        staleSuites: rebuild.stale,
        cacheHits: rebuild.cacheHits,
        pass: false,
        graphMs: graphWatch.elapsedMilliseconds,
        rebuildMs: rebuild.rebuildMs,
        runMs: 0,
        rebuildError: rebuild.failure!.output.trim(),
        refusedFlutterSuites: refused,
        uncoveredChanges: coverage.uncovered,
        broadenReason: broadenReason,
      )..write(receiptPath);
      return VerifyResult(
        exitCode: 65,
        receipt: receipt,
        receiptPath: receiptPath,
        selectedSuites: runnable,
        refusedFlutterSuites: refused,
        broadenReason: broadenReason,
      );
    }

    if (options.noRun) {
      final receipt = VerifyReceipt(
        revision: revision,
        sdkVersion: Platform.version,
        packageName: options.packageName,
        changedFiles: changed,
        selectedSuites: runnable,
        rebuiltSuites: rebuild.rebuilt,
        staleSuites: rebuild.stale,
        cacheHits: rebuild.cacheHits,
        pass: true,
        graphMs: graphWatch.elapsedMilliseconds,
        rebuildMs: rebuild.rebuildMs,
        runMs: 0,
        refusedFlutterSuites: refused,
        uncoveredChanges: coverage.uncovered,
        broadenReason: broadenReason,
      )..write(receiptPath);
      return VerifyResult(
        exitCode: 0,
        receipt: receipt,
        receiptPath: receiptPath,
        selectedSuites: runnable,
        refusedFlutterSuites: refused,
        broadenReason: broadenReason,
      );
    }

    final runner = testRunner ?? DartTestRunner(budget: budget);
    final precompiledDir = builder.precompiledDir;
    final run = await runner.runSuites(
      runnable,
      workingDirectory: packageRoot,
      precompiledDir: precompiledDir,
    );
    final receipt = VerifyReceipt(
      revision: revision,
      sdkVersion: Platform.version,
      packageName: options.packageName,
      changedFiles: changed,
      selectedSuites: runnable,
      rebuiltSuites: rebuild.rebuilt,
      staleSuites: rebuild.stale,
      cacheHits: rebuild.cacheHits,
      pass: run.ok,
      graphMs: graphWatch.elapsedMilliseconds,
      rebuildMs: rebuild.rebuildMs,
      runMs: run.duration.inMilliseconds,
      refusedFlutterSuites: refused,
      uncoveredChanges: coverage.uncovered,
      broadenReason: broadenReason,
      outputTruncated: run.outputTruncated,
      timedOut: run.timedOut,
    )..write(receiptPath);
    return VerifyResult(
      exitCode: run.ok ? 0 : 1,
      receipt: receipt,
      receiptPath: receiptPath,
      selectedSuites: runnable,
      refusedFlutterSuites: refused,
      broadenReason: broadenReason,
    );
  }

  VerifyResult _fatal(VerifyOptions options, String message) {
    _emit(message);
    final receipt = VerifyReceipt(
      revision: 'unknown',
      sdkVersion: Platform.version,
      packageName: options.packageName,
      changedFiles: const <String>[],
      selectedSuites: const <String>[],
      rebuiltSuites: const <String>[],
      cacheHits: 0,
      pass: false,
      graphMs: 0,
      rebuildMs: 0,
      runMs: 0,
      rebuildError: message,
    );
    return VerifyResult(
      exitCode: 66,
      receipt: receipt,
      receiptPath: '',
      selectedSuites: const <String>[],
      error: message,
    );
  }

  void _emit(String message) {
    final sink = log;
    if (sink == null) return;
    sink('[oka-verify] $message');
  }
}
