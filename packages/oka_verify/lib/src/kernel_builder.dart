/// The kernel builder seam of the oka verify lane (ADR-0048).
///
/// The orchestration talks to compiled suite kernels through this
/// interface, so the composition of a run (selection → kernels → runner)
/// can be tested without a compiler, and a consumer can substitute its own
/// kernel source.
library;

import 'kernel_cache.dart';

/// Builds (or reuses) the compiled kernels of the selected suites.
abstract interface class SuiteKernelBuilder {
  /// The directory `dart test --precompiled` consumes.
  String get precompiledDir;

  /// Ensures a kernel exists and is fresh for every suite in [suites].
  ///
  /// [onRebuilt] is called after each rebuilt kernel, [onFailed] when a
  /// suite fails to compile. The returned result names the first failure.
  Future<KernelRebuildResult> ensureKernels(
    List<String> suites, {
    void Function(String suite)? onRebuilt,
    void Function(String suite, String output)? onFailed,
  });
}
