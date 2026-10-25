/// Kernel cache for the oka verify lane (ADR-0048): suites compile once
/// into bootstrapped dills keyed by their import-closure content hash.
///
/// The cache is a projection — deleting it must never change results,
/// only latency. Staleness is content-derived (closure hash + package
/// configuration + SDK version + bootstrap contract), never trusted from
/// mtimes alone.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'budget.dart';
import 'cache_key.dart';
import 'frontend_server_session.dart';
import 'import_graph.dart';
import 'kernel_builder.dart';
import 'suite_bootstrap.dart';

/// What one `ensureKernels` pass did.
final class KernelRebuildResult {
  KernelRebuildResult({
    required this.rebuilt,
    required this.stale,
    required this.cacheHits,
    required this.rebuildMs,
    this.failure,
  });

  /// The suites whose kernel was actually (re)built.
  final List<String> rebuilt;

  /// The suites whose cached kernel was stale — the ones that needed a
  /// rebuild, whether or not the pass got to them.
  final List<String> stale;

  /// The suites whose cached kernel was still valid.
  final int cacheHits;

  /// Wall clock of the whole pass.
  final int rebuildMs;

  /// The first compile failure, with its owning suite.
  final RebuildFailure? failure;

  /// True when no compile failed.
  bool get ok => failure == null;
}

/// One compile failure, with the suite that owns it.
final class RebuildFailure implements Exception {
  RebuildFailure({required this.suite, required this.output});

  /// The suite that failed to compile.
  final String suite;

  /// The compiler output (bounded).
  final String output;

  @override
  String toString() => 'kernel rebuild failed for $suite:\n$output';
}

/// The content-keyed suite-kernel cache.
final class KernelCache implements SuiteKernelBuilder {
  KernelCache({
    required this.repoRoot,
    required this.graph,
    required String packageRoot,
    required this.packageName,
    int? workers,
    VerifyBudget? budget,
    this.injectedContext,
  }) : _workers = workers ?? (budget ?? const VerifyBudget()).workers,
       _budget = budget ?? const VerifyBudget(),
       _packageRoot = _noTrailingSlash(Directory(packageRoot).absolute.path),
       cacheDir = Directory(
         '${Directory(repoRoot).absolute.path}/.dart_tool/oka_verify',
       ).absolute.path;

  /// The workspace root that owns the package configuration.
  final String repoRoot;

  /// The graph that resolves each suite's import closure.
  final WorkspaceGraph graph;

  /// The package the cached kernels belong to.
  final String packageName;

  final String _packageRoot;
  final int _workers;
  final VerifyBudget _budget;

  /// An explicit key context, overriding the environment-derived one.
  final CacheKeyContext? injectedContext;

  /// `<root>/.dart_tool/oka_verify` — safe to delete at any time.
  final String cacheDir;

  /// `<root>/.dart_tool/oka_verify/<package>/precompiled` — the directory
  /// `dart test --precompiled` consumes.
  @override
  late final String precompiledDir = '$cacheDir/$packageName/precompiled';

  /// `<root>/.dart_tool/oka_verify/<package>/boot` — the generated entry
  /// points.
  late final String bootDir = '$cacheDir/$packageName/boot';

  static String _noTrailingSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// The dill path the test_core precompiled contract expects for
  /// [suitePath] (a `<path>.vm_test.vm.app.dill` next to a mirrored
  /// `<path>.vm_test.dart` stub location).
  String dillPath(String suitePath) {
    final rel = _relativeToPackage(suitePath);
    return '$precompiledDir/$rel.vm_test.vm.app.dill';
  }

  /// The cache key of one suite: its import closure's content, the SDK, the
  /// package configuration and the bootstrap contract.
  String suiteKey(String suite) {
    graph.refresh();
    return _suiteKey(suite);
  }

  String _suiteKey(String suite, [Map<String, String>? runHashes]) {
    final closure = graph.closureOf(suite);
    final hashes = <String, String>{
      for (final file in closure)
        file: runHashes == null
            ? hashFile(file)
            : runHashes.putIfAbsent(file, () => hashFile(file)),
    };
    return computeSuiteKey(
      closure: closure,
      fileHashes: hashes,
      context: context,
    );
  }

  /// The environment facts every key carries.
  CacheKeyContext get context {
    final injected = injectedContext;
    if (injected != null) return injected;
    return _currentContext();
  }

  CacheKeyContext _currentContext() {
    final config = _rootPackageConfig;
    final json = config.existsSync() ? config.readAsStringSync() : '';
    return CacheKeyContext.current(
      packageConfigJson: json,
      sdkVersion: Platform.version,
      contractVersion: bootstrapContractVersion,
    );
  }

  /// Ensures dills exist and are fresh for [suites]. Returns what was
  /// rebuilt vs cache-hit; a compile failure stops scheduling new builds
  /// and is reported with its owning suite.
  @override
  Future<KernelRebuildResult> ensureKernels(
    List<String> suites, {
    void Function(String suite)? onRebuilt,
    void Function(String suite, String output)? onFailed,
  }) async {
    final watch = Stopwatch()..start();
    Directory(precompiledDir).createSync(recursive: true);
    Directory(bootDir).createSync(recursive: true);
    _copyPackageConfig();

    final keys = _loadKeys();
    final stale = <String>[];
    var cacheHits = 0;
    graph.refresh();
    final runHashes = <String, String>{};
    final selectedKeys = {
      for (final suite in suites) suite: _suiteKey(suite, runHashes),
    };
    for (final suite in suites) {
      final fresh =
          keys[suite] == selectedKeys[suite] &&
          File(dillPath(suite)).existsSync();
      if (fresh) {
        cacheHits++;
      } else {
        stale.add(suite);
      }
    }

    final rebuilt = <String>[];
    RebuildFailure? failure;
    // The warm session is the accelerator; the process pool is the backstop.
    // Whatever the session cannot build (unavailable front end, broken
    // compile, artifact that never lands) goes to the pool — a missing
    // dill must fail loudly, never silently skip.
    final fallback = <String>[];
    try {
      final session = await _startSession();
      try {
        for (final suite in stale) {
          try {
            // Write the boot source BEFORE the session compile — the
            // pool backstop does this in _compileSuite; a fresh cache
            // with a live warm session never had it on disk.
            final bootPath = '$bootDir/${_relativeToPackage(suite)}.boot.dart';
            File(bootPath).parent.createSync(recursive: true);
            File(dillPath(suite)).parent.createSync(recursive: true);
            File(bootPath).writeAsStringSync(
              suiteBootstrapSource(
                suitePath: suite,
                bootDir: File(bootPath).parent.path,
              ),
            );
            final result = await session
                .compile(bootPath, copyTo: dillPath(suite))
                .timeout(
                  _budget.compileTimeout,
                  onTimeout: () => throw RebuildFailure(
                    suite: suite,
                    output: 'compile exceeded its configured budget',
                  ),
                );
            if (!result.ok) {
              onFailed?.call(suite, result.diagnostics);
              failure ??= RebuildFailure(
                suite: suite,
                output: result.diagnostics,
              );
              break;
            }
            if (!File(dillPath(suite)).existsSync()) {
              throw FrontendServerException(
                'front end reported ok but wrote no dill for $suite',
              );
            }
            final unstable = _checkCompiledSource(suite, selectedKeys[suite]!);
            if (unstable != null) {
              onFailed?.call(suite, unstable.output);
              failure = unstable;
              break;
            }
            keys[suite] = selectedKeys[suite];
            _saveKeys(keys);
            rebuilt.add(suite);
            onRebuilt?.call(suite);
          } on RebuildFailure catch (error) {
            onFailed?.call(suite, error.output);
            failure = error;
            break;
          } on FrontendServerException catch (e) {
            stderr.writeln(
              '[oka-verify] session build fell back to pool: ${e.message}',
            );
            fallback.addAll(stale.where((s) => !fallback.contains(s)));
            break;
          }
        }
      } finally {
        await session.quit();
      }
    } on FrontendServerException {
      fallback.addAll(stale);
    }
    if (fallback.isNotEmpty) {
      failure = await _rebuildInParallel(
        fallback,
        keys,
        rebuilt,
        onRebuilt,
        onFailed,
        selectedKeys,
      );
    }
    watch.stop();
    return KernelRebuildResult(
      rebuilt: rebuilt,
      stale: stale,
      cacheHits: cacheHits,
      rebuildMs: watch.elapsedMilliseconds,
      failure: failure,
    );
  }

  /// One warm frontend front end serves every suite kernel: sequential
  /// compiles share the CFE's SDK/package state, which measured 0.6–3.5 s
  /// per suite versus ~20–26 s per suite for per-suite process boots.
  Future<FrontendServerSession> _startSession() {
    final sdk = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final sdkRoot = Directory(File(sdk).parent.parent.path).path;
    return FrontendServerSession.start(
      sdkRoot: sdkRoot,
      scratchDill:
          '$cacheDir/$packageName/session-${DateTime.now().microsecondsSinceEpoch}.dill',
      packagesPath: _rootPackageConfig.path,
    );
  }

  Future<RebuildFailure?> _rebuildInParallel(
    List<String> stale,
    Map<String, Object?> keys,
    List<String> rebuilt,
    void Function(String)? onRebuilt,
    void Function(String, String)? onFailed,
    Map<String, String> selectedKeys,
  ) async {
    final queue = Queue<String>.of(stale);
    RebuildFailure? failure;
    await Future.wait([
      for (var w = 0; w < _workers; w++)
        Future(() async {
          while (queue.isNotEmpty && failure == null) {
            final suite = queue.removeFirst();
            try {
              await _compileSuite(suite);
              final unstable = _checkCompiledSource(
                suite,
                selectedKeys[suite]!,
              );
              if (unstable != null) throw unstable;
              keys[suite] = selectedKeys[suite];
              _saveKeys(keys);
              rebuilt.add(suite);
              onRebuilt?.call(suite);
            } on RebuildFailure catch (e) {
              onFailed?.call(e.suite, e.output);
              failure ??= e;
            }
          }
        }),
    ]);
    return failure;
  }

  /// Compiles one suite with a bounded `dart compile kernel` process.
  Future<void> _compileSuite(String suite) async {
    final bootPath = '$bootDir/${_relativeToPackage(suite)}.boot.dart';
    final dill = dillPath(suite);
    File(bootPath).parent.createSync(recursive: true);
    File(dill).parent.createSync(recursive: true);
    File(bootPath).writeAsStringSync(
      suiteBootstrapSource(
        suitePath: suite,
        bootDir: File(bootPath).parent.path,
      ),
    );
    final result = await runBoundedProcess(
      Platform.resolvedExecutable,
      ['compile', 'kernel', bootPath, '-o', dill],
      workingDirectory: repoRoot,
      timeout: _budget.compileTimeout,
      maxCapturedBytes: _budget.maxCapturedBytes,
    );
    if (result.cause == BoundedRunCause.killedOnDeadline) {
      throw RebuildFailure(
        suite: suite,
        output:
            'compile exceeded ${_budget.compileTimeout.inSeconds}s and was '
            'stopped.\n${result.stdout}${result.stderr}',
      );
    }
    if (result.cause == BoundedRunCause.spawnFailed) {
      throw RebuildFailure(
        suite: suite,
        output: 'could not start the compiler: ${result.errorMessage}',
      );
    }
    if (result.exitCode != 0 || !File(dill).existsSync()) {
      throw RebuildFailure(
        suite: suite,
        output: '${result.stdout}${result.stderr}',
      );
    }
  }

  void _copyPackageConfig() {
    final source = _rootPackageConfig;
    if (!source.existsSync()) return;
    final target = File('$precompiledDir/.dart_tool/package_config.json');
    final copied = _absoluteRootUris(
      source.readAsStringSync(),
      source.parent.path,
    );
    if (!target.existsSync() || target.readAsStringSync() != copied) {
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(copied);
    }
  }

  /// The copy lives deeper than the original, so relative rootUris would
  /// resolve to nonexistent paths at isolate spawn. Absolute-ize them.
  String _absoluteRootUris(String json, String configDir) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return json;
    final packages = decoded['packages'];
    if (packages is! List<Object?>) return json;
    decoded['packages'] = [
      for (final entry in packages)
        if (entry is Map<String, Object?>) _absolutizeRootUri(entry, configDir),
    ];
    return jsonEncode(decoded);
  }

  Map<String, Object?> _absolutizeRootUri(
    Map<String, Object?> pkg,
    String configDir,
  ) {
    final value = pkg['rootUri'];
    if (value is! String) return pkg;
    return pkg
      ..['rootUri'] = Uri.parse(value).isAbsolute
          ? value
          : Uri.directory('$configDir/')
                .resolveUri(Uri.parse(value))
                .toString();
  }

  Map<String, Object?> _loadKeys() {
    final file = File('$cacheDir/$packageName/keys.json');
    if (!file.existsSync()) return {};
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) return {};
    return decoded;
  }

  void _saveKeys(Map<String, Object?> keys) {
    File('$cacheDir/$packageName/keys.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(keys));
  }

  File get _rootPackageConfig =>
      File('$repoRoot/.dart_tool/package_config.json');

  RebuildFailure? _checkCompiledSource(String suite, String selectedKey) {
    if (suiteKey(suite) == selectedKey) return null;
    final dill = File(dillPath(suite));
    if (dill.existsSync()) dill.deleteSync();
    return RebuildFailure(
      suite: suite,
      output:
          'source_changed_during_compile: inputs changed after selection; '
          'the kernel was discarded. Verify a stable revision.',
    );
  }

  /// Compatibility hook. Content is hashed once per source in each selection;
  /// persisted mtime/size hints cannot establish content identity.
  void saveFileHashes() {}

  String _relativeToPackage(String path) => path.startsWith('$_packageRoot/')
      ? path.substring(_packageRoot.length + 1)
      : throw ArgumentError('suite outside package: $path');
}
