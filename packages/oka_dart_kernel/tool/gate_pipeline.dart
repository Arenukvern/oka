/// ADR-0032 G1b/G2: a minimal kernel pipeline that mirrors
/// `pkg/vm/lib/kernel_front_end.dart`'s flow — CFE compile (`kernelForProgram`)
/// → [transformHook] → VM global transformations (TFA et al.) → serialize.
///
/// The hook is where oka's kernel transforms run (G2: deferred-ization).
/// With `--deferredize`, the hook flips `LibraryDependency.DeferredFlag` on
/// the dependency targeting the unit library and inserts an
/// `await LoadLibrary(dep)` at the start of `main` — after which gen_snapshot
/// partitions loading units per the transform, with no source annotations.
///
/// Compile/run with `-Dsdk_hash=<10-char hash>` (kernel's expectedSdkHash is a
/// compile-time constant; C++ backends gate on it) and a package_config that
/// maps kernel/vm/front_end (+ deps) to a pinned SDK checkout — see
/// tool/gate_g1b_g2.sh.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerContext,
        CompilerOptions,
        CfeSeverity,
        ProcessedOptions,
        StandardFileSystem,
        kernelForModule,
        kernelForProgram,
        printDiagnosticMessage;
import 'package:vm/kernel_front_end.dart'
    show ErrorDetector, KernelCompilationArguments;
import 'package:vm/modular/target/install.dart' show installAdditionalTargets;
import 'package:vm/modular/transformations/call_site_annotator.dart'
    as call_site_annotator;
import 'package:vm/transformations/deferred_loading.dart' as deferred_loading;
import 'package:vm/transformations/mixin_deduplication.dart'
    as mixin_deduplication;
import 'package:vm/transformations/obfuscation_prohibitions_annotator.dart'
    as obfuscation_prohibitions;
import 'package:vm/transformations/type_flow/transformer.dart'
    as globalTypeFlow;
import 'package:vm/transformations/unreachable_code_elimination.dart'
    as unreachable_code_elimination;
import 'package:vm/transformations/vm_constant_evaluator.dart'
    as vm_constant_evaluator;
import 'package:vm/target_os.dart' show TargetOS;
import 'deferredize.dart';

final _byteSink = BytesBuilder();

class _ByteSink implements Sink<List<int>> {
  @override
  void add(List<int> chunk) => _byteSink.add(chunk);
  @override
  void close() {}
}

Future<Component> compile(Uri entry, CompilerOptions options,
    {bool delta = false}) async {
  if (delta) {
    // Library reload root: kernelForProgram requires a `main` (returns null
    // for a library entry), kernelForModule compiles the unit closure with
    // dart:* kept as external summary libraries.
    final moduleResult = await kernelForModule([entry], options);
    final moduleComponent = moduleResult.component;
    if (moduleComponent == null) {
      throw StateError('delta compilation produced no component');
    }
    return moduleComponent;
  }
  final processed = ProcessedOptions(
    options: options,
    inputs: [entry],
  );
  final result = await CompilerContext.runWithOptions(processed, (_) async {
    return kernelForProgram(entry, options);
  });
  final component = result!.component;
  if (component == null) {
    throw StateError('compilation produced no component');
  }
  return component;
}

/// The transform hook. Empty `units` = no-op (G1b); each listed unit pattern
/// (`package:foo/` prefix or `path/suffix.dart`) is partitioned with
/// dependency ordering (G2.5): cross-boundary imports flagged deferred,
/// synthetic deferred imports on the entry, `await LoadLibrary` guards
/// inserted at the start of `main` in dependency order — no source changes.
DeferredizeResult? transformHook(
  Component component,
  List<String> units, {
  bool insertGuards = true,
}) {
  if (units.isEmpty) {
    stdout.writeln('hook: noop');
    return null;
  }
  return deferredizeUnits(component, units, insertGuards: insertGuards);
}

Future<void> main(List<String> arguments) async {
  final units = <String>[];
  for (final a in arguments) {
    if (a.startsWith('--unit=')) units.add(a.substring('--unit='.length));
  }
  if (arguments.contains('--deferredize') && units.isEmpty) {
    units.add('units/tiny.dart');
  }
  final noGuards = arguments.contains('--no-guards');
  final paths = arguments
      .where((a) => !a.startsWith('--') && !(a.startsWith('--unit=')))
      .toList();
  if (paths.length != 2) {
    stderr.writeln(
      'usage: gate_pipeline.dart [--delta] [--deferredize] [--no-guards] '
      '[--unit=<path-suffix>]... <entry.dart> <out.dill>',
    );
    exitCode = 2;
    return;
  }
  final delta = arguments.contains('--delta');
  final entry = Uri.file(File(paths[0]).absolute.path);
  final out = paths[1];

  final sdkRoot = Platform.environment['DART_SDK_ROOT'];
  // Platform dill override for non-stock platforms (e.g. a Flutter patched
  // SDK when compiling a real Flutter app entry).
  final summaryPath = Platform.environment['DART_SDK_SUMMARY'] ??
      (sdkRoot == null ? null : '$sdkRoot/lib/_internal/vm_platform_strong.dill');
  if (summaryPath == null || !File(summaryPath).existsSync()) {
    throw StateError(
      'DART_SDK_SUMMARY (or DART_SDK_ROOT) must point at a platform dill '
      '(got: $summaryPath)',
    );
  }
  final errorDetector = ErrorDetector(
    previousErrorHandler: (message) =>
        printDiagnosticMessage(message, (line) => stderr.writeln(line)),
  );

  final target = () {
    // OKA_TARGET=flutter when compiling against a Flutter patched SDK (its
    // platform dill lacks the stock VM target's extra required libraries).
    installAdditionalTargets();
    return getTarget(
      Platform.environment['OKA_TARGET'] ?? 'vm',
      TargetFlags(),
    )!;
  }();
  final options = CompilerOptions()
    ..fileSystem = StandardFileSystem.instance
    // sdkSummary alone: platform dill supplies dart:* (sdkRoot would make the
    // CFE recompile the SDK from source instead).
    ..sdkSummary = Uri.file(summaryPath)
    ..target = target
    ..environmentDefines = const {}
    ..packagesFileUri = Platform.environment['DART_PACKAGES_CONFIG'] == null
        ? null
        : Uri.file(Platform.environment['DART_PACKAGES_CONFIG']!)
    ..onDiagnostic = errorDetector;

  stdout.writeln('pipeline: compiling ${entry.path}');
  final component = await compile(entry, options, delta: delta);
  stdout.writeln(
    'pipeline: compiled, ${component.libraries.length} libraries',
  );

  if (delta) {
    // JIT delta lane (ADR-0032 G3 per-unit reload): the reload root IS the
    // unit library, so the delta holds only that library. The stock
    // frontend_server cannot produce this — recompile-from-entry (any root)
    // invalidates every transitive dependent (measured 135MB on last_answer;
    // the VM's kernel isolate refuses the payload). kernelForProgram with
    // the entry library gives the unit closure; pruning to the unit's own
    // file leaves external canonical-name references for everything else,
    // which the VM resolves against the loaded program at reload time.
    final entryFile = entry.toString();
    final kept = component.libraries
        .where((lib) => lib.fileUri.toString() == entryFile)
        .toList();
    if (kept.length != 1) {
      throw StateError(
        'delta mode: expected exactly 1 library at $entryFile, '
        'matched ${kept.length}',
      );
    }
    component.libraries
      ..clear()
      ..addAll(kept);
    final deltaSink = _ByteSink();
    BinaryPrinter(deltaSink).writeComponentFile(component);
    File(out).writeAsBytesSync(_byteSink.takeBytes());
    stdout.writeln(
      'pipeline: delta ${File(out).lengthSync()} bytes '
      '(${kept.single.importUri})',
    );
    return;
  }

  final result = transformHook(component, units, insertGuards: !noGuards);

  final args = KernelCompilationArguments(
    source: entry,
    options: options,
    aot: true,
    useGlobalTypeFlowAnalysis: true,
    useRapidTypeAnalysis: true,
    treeShakeWriteOnlyFields: true,
    enableAsserts: false,
    // Overridable for cross-target manifests (e.g. linux ELF from macOS).
    targetOS: Platform.environment['OKA_TARGET_OS'] ?? Platform.operatingSystem,
    environmentDefines: options.environmentDefines ?? const {},
  );
  await runGlobalTransformationsWithUnits(
    target,
    component,
    errorDetector,
    args,
    result,
  );
  if (errorDetector.hasCompilationErrors) {
    throw StateError('compilation errors');
  }

  final metadataSizes = component.metadata.values
      .map((r) => '${r.tag}: ${r.mapping.length}')
      .toList()
    ..sort();
  stdout.writeln('pipeline: metadata $metadataSizes');

  final sink = _ByteSink();
  final printer = BinaryPrinter(sink);
  printer.writeComponentFile(component);
  File(out).writeAsBytesSync(_byteSink.takeBytes());
  stdout.writeln('pipeline: wrote $out');
}

/// `runGlobalTransformations` expanded into its own steps so oka can hook
/// between the mid-pipeline transformations and the loading-unit computation:
/// `dart:mixin_deduplication` (and friends) synthesize libraries with fresh
/// non-deferred edges into unit members, which would drag the members back
/// into the root loading unit — [result] re-flags those edges right before
/// `deferred_loading` runs. Mirrors
/// `pkg/vm/lib/kernel_front_end.dart#runGlobalTransformations`.
Future<void> runGlobalTransformationsWithUnits(
  Target target,
  Component component,
  ErrorDetector errorDetector,
  KernelCompilationArguments args,
  DeferredizeResult? result,
) async {
  if (errorDetector.hasCompilationErrors) return;

  final coreTypes = CoreTypes(component);

  mixin_deduplication.transformComponent(component, coreTypes, target);

  final targetOS = args.targetOS;
  final os = targetOS != null ? TargetOS.fromString(targetOS) : null;
  final evaluator = vm_constant_evaluator.VMConstantEvaluator.create(
    target,
    component,
    os,
    enableAsserts: args.enableAsserts,
    environmentDefines: args.environmentDefines,
    coreTypes: coreTypes,
  );
  unreachable_code_elimination.transformComponent(
    target,
    component,
    evaluator,
    args.enableAsserts,
  );

  if (args.useGlobalTypeFlowAnalysis) {
    globalTypeFlow.transformComponent(
      target,
      coreTypes,
      component,
      treeShakeSignatures: !args.minimalKernel,
      treeShakeWriteOnlyFields: args.treeShakeWriteOnlyFields,
      treeShakeProtobufs: args.useProtobufTreeShakerV2,
      treeShakeProtobufMixins: args.protobufTreeShakerMixins,
      useRapidTypeAnalysis: args.useRapidTypeAnalysis,
    );
  }

  void ignoreAmbiguousSupertypes(cls, a, b) {}
  final hierarchy = ClassHierarchy(
    component,
    coreTypes,
    onAmbiguousSupertypes: ignoreAmbiguousSupertypes,
  );
  call_site_annotator.transformLibraries(
    component,
    component.libraries,
    coreTypes,
    hierarchy,
  );

  obfuscation_prohibitions.transformComponent(
    component,
    coreTypes,
    target,
    hierarchy,
    args.keepClassNamesImplementing,
  );

  // The oka hook point: units survive mid-pipeline synthetic libraries.
  result?.reapplyDeferredFlags(component);

  deferred_loading.transformComponent(component, coreTypes, target);
}
