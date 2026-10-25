# oka_verify

The fast Dart verification lane as a reusable package
([ADR-0048](../../docs/decisions/0048-oka-verify-fast-dart-verification-package.mdx)):
**pay Dart's compile cost once per suite, not once per iteration.** Suite
kernels are cached artifacts keyed by their import closure's content,
rebuilt only when a changed file transitively reaches them, and run through
`dart test --precompiled` — no Common Front End pass in the steady state.

Extracted from the agentic harness's verify lane (harness ADR 0098), which
measured a full-package kernel rebuild at 547 s → **98.7 s** with a warm
frontend server and a warm full-package validation at **3.74 s**.

## 60-second version

```bash
# verify what changed (suites whose closure reaches a changed file)
dart run bin/oka_verify.dart --package my_package

# narrow, widen, warm the cache
dart run bin/oka_verify.dart --package my_package --only widget
dart run bin/oka_verify.dart --package my_package --all
dart run bin/oka_verify.dart --package my_package --no-run
```

```dart
final result = await OkaVerify(log: stderr.writeln).run(
  VerifyOptions(repoRoot: '/path/to/workspace', packageName: 'my_package'),
);
print(result.receipt.encode()); // revision, SDK, changed files, timings
```

The exit code mirrors `dart test`. The last stderr line is always
`oka-receipt: <path>` — a JSON receipt naming the git revision, the SDK,
the changed files, the selected/rebuilt/cache-hit counts, the phase timings
and the suites the lane refused.

## The four laws

1. **Dart SDK only. Widget suites are refused, not skipped.** A suite whose
   closure imports `package:flutter/` or `package:flutter_test/` needs the
   `flutter_tester` shell. The lane refuses it loudly (stderr line +
   receipt field), excludes it from the run, and points at `flutter test`.
   A package with only widget suites exits 66 with that boundary named.
2. **Plain `dart test` stays the acceptance oracle.** The lane is iteration
   evidence; every receipt names its own revision, so a stale state cannot
   masquerade as a green run.
3. **Cache keys carry the source closure, the SDK and the package
   configuration.** A kernel is valid only while every file of its
   transitive import closure is byte-identical, the SDK is unchanged, the
   root `package_config.json` is unchanged and the bootstrap contract
   version is unchanged. Import, export, part and **conditional** import
   edges are all followed — a conditional import contributes *all* of its
   branches, because a branch not taken on this platform is still an edge
   the cache cannot prove irrelevant. The cache is a projection: deleting
   it changes latency, never results.
4. **Unknown dependency coverage widens the run.** A change the import
   graph cannot attribute — a dependency descriptor (`pubspec.yaml`,
   `pubspec.lock`, `package_config.json`), a non-Dart file inside the
   package under test, a `.dart` file outside every known package — selects
   **every** suite of the package, with the reason named in the receipt. A
   skipped check is a silent false green; a wider run is only slower.

## Bounded by default

Every external process runs under an explicit budget
(`VerifyBudget`): compile timeout, run timeout, worker count, captured
output bytes. Compiles and the short git queries go through oka's process
substrate (`oka_core`'s bounded run: deadline → tree stop → teardown
receipt). The runner's deadline stops the process tree, not just the root
process. Output beyond the budget is dropped and the truncation is
reported, never silently swallowed.

## Where to look

- ADR-0048 for the why (and the boundaries: no Flutter, no eval channel,
  no resident runner).
- `lib/src/import_graph.dart` — the dependency-free directive scan
  (import/export/part/conditional) and the reverse closure.
- `lib/src/kernel_cache.dart` — the content-keyed, parallel
  `dart compile kernel` cache under `.dart_tool/oka_verify/`.
- `lib/src/suite_bootstrap.dart` — the generated `internalBootstrapVmTest`
  entry point the `--precompiled` contract expects.
- `lib/src/selection.dart` — the pure selection function (all / only /
  affected / widened).
- `lib/src/verify_runner.dart` — the orchestration and the receipt.
- Tests: `test/` — selection parity, cache invalidation, coverage
  widening, failure paths, and an end-to-end proof that a real suite
  compiles, caches and runs through `dart test --precompiled`.
