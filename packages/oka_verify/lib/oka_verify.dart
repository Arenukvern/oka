/// The fast Dart verification lane (ADR-0048).
///
/// The lane pays Dart's compile cost once per suite instead of once per
/// iteration: suite kernels are cached artifacts keyed by their import
/// closure's content, rebuilt only when a changed file transitively
/// reaches them, and run through `dart test --precompiled` — no Common
/// Front End pass in the steady state.
///
/// ```dart
/// final result = await OkaVerify(
///   log: stderr.writeln,
/// ).run(
///   VerifyOptions(
///     repoRoot: '/path/to/workspace',
///     packageName: 'my_package',
///   ),
/// );
/// ```
///
/// The boundaries the lane keeps:
///
/// * **Dart SDK only.** Widget suites are refused loudly, not skipped;
///   `flutter test` remains their oracle.
/// * **Plain `dart test` stays the acceptance oracle.** A receipt is
///   iteration evidence and always names its revision, SDK, changed files
///   and the suites the lane refused.
/// * **Unknown coverage widens the run.** A change the import graph cannot
///   attribute selects every suite of the package instead of silently
///   narrowing the checks.
library;

export 'src/budget.dart';
export 'src/cache_key.dart';
export 'src/coverage.dart';
export 'src/frontend_server_session.dart';
export 'src/git.dart';
export 'src/import_graph.dart';
export 'src/kernel_builder.dart';
export 'src/kernel_cache.dart';
export 'src/receipt.dart';
export 'src/selection.dart';
export 'src/suite_bootstrap.dart';
export 'src/test_runner.dart';
export 'src/verify_runner.dart';
