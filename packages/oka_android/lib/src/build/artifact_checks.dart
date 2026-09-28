/// Package-time artifact validation (ADR-0029 D2): validate before side
/// effects. Each check inspects the staged artifact the way a post-mortem
/// would — engine↔snapshot pairing, engine variant vs build mode,
/// provenance completeness — and a failing check fails the build *before
/// signing*, so a wrong artifact cannot ship.
///
/// Extension contract for developers composing on top of oka: implement
/// [ArtifactCheck] and compose [ValidateArtifactStep] with your checks in
/// the project's step list:
///
/// ```dart
/// steps: [
///   ...AndroidPipeline.defaultSteps,
///   // Insert before packaging in a custom list, or rely on the default
///   // pipeline's built-in checks and add a second validation pass:
///   ValidateArtifactStep(checks: [MyLicenseCheck()]),
/// ]
/// ```
///
/// Checks must be pure with respect to the build: they read staged files
/// and pipeline state, never the network or a device.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../android_state.dart';
import 'apk_layout.dart';
import 'engine_artifacts.dart';
import 'provenance.dart';

/// Outcome of one [ArtifactCheck].
class ArtifactCheckVerdict {
  const ArtifactCheckVerdict.ok(this.checkName, [this.detail = ''])
    : passed = true;
  const ArtifactCheckVerdict.fail(this.checkName, this.detail)
    : passed = false;
  const ArtifactCheckVerdict.skip(this.checkName, [this.detail = ''])
    : passed = true;

  final String checkName;
  final bool passed;
  final String detail;

  @override
  String toString() => passed
      ? '✅ $checkName${detail.isEmpty ? '' : ' — $detail'}'
      : '❌ $checkName — $detail';
}

/// Context handed to checks: the build and its staged state. Deliberately
/// narrow — checks read; they never mutate.
class ArtifactCheckContext {
  const ArtifactCheckContext(this.ctx, this.state);
  final BuildContext ctx;
  final PipelineState state;

  /// Staged `libflutter.so` for [abi] (normalized), or null.
  String? libflutterFor(final String abi) =>
      state.libflutterByAbi[normalizeAbi(abi)];

  /// Staged `libapp.so` for [abi] (normalized), or null (debug builds).
  String? libappFor(final String abi) => state.libappByAbi[normalizeAbi(abi)];
}

/// One artifact validation. Implementations must be deterministic and
/// offline; a check that cannot decide (missing inputs) returns
/// [ArtifactCheckVerdict.ok] only when the absence is legitimate for the
/// mode (e.g. no AOT in debug) and says so in [ArtifactCheckVerdict.detail].
abstract interface class ArtifactCheck {
  String get name;
  Future<ArtifactCheckVerdict> check(ArtifactCheckContext context);
}

/// The Dart snapshot version hash is a 32-hex string embedded in both the
/// AOT snapshot (`libapp.so`) and the engine that must run it
/// (`libflutter.so`). In `libapp.so` it is immediately followed by the
/// feature string (e.g. `product no-asan …`); in the engine it appears as a
/// standalone string. Both may sit near ELF note build-ids, so candidates
/// are intersected rather than trusted on sight.
List<String> extractDartSnapshotVersionCandidates(final List<int> bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  final re = RegExp('(?<![0-9a-f])([0-9a-f]{32})(?![0-9a-f])');
  final candidates = <String>{};
  for (final m in re.allMatches(text)) {
    final after = text.substring(
      m.end,
      m.end + 24 > text.length ? text.length : m.end + 24,
    );
    final isSnapshotStyle =
        after.startsWith('product') ||
        after.startsWith('profile') ||
        after.startsWith('debug') ||
        after.startsWith('no-');
    final precededByWordChar =
        m.start > 0 && RegExp('[A-Za-z0-9_]').hasMatch(text[m.start - 1]);
    if (isSnapshotStyle || !precededByWordChar) {
      candidates.add(m.group(1)!);
    }
  }
  return candidates.toList(growable: false);
}

/// Verifies the staged AOT snapshot was built for the staged engine: the
/// Dart snapshot version candidates in `libapp.so` and `libflutter.so` must
/// intersect on exactly one hash (the 2026-09-27 incident shipped a snapshot
/// the engine rejected — "VM snapshot invalid" — despite a matching-looking
/// build).
///
/// Debug builds have no AOT snapshot: the check skips with a note.
class SnapshotEnginePairingCheck implements ArtifactCheck {
  const SnapshotEnginePairingCheck();

  @override
  String get name => 'snapshot-engine-pairing';

  @override
  Future<ArtifactCheckVerdict> check(
    final ArtifactCheckContext context,
  ) async {
    final abi = context.state.abis.isEmpty
        ? 'arm64-v8a'
        : normalizeAbi(context.state.abis.first);
    final libapp = context.libappFor(abi);
    if (libapp == null || !File(libapp).existsSync()) {
      return ArtifactCheckVerdict.skip(
        name,
        'no staged AOT snapshot (${context.ctx.mode.name} build) — nothing '
        'to pair',
      );
    }
    final libflutter = context.libflutterFor(abi);
    if (libflutter == null || !File(libflutter).existsSync()) {
      return ArtifactCheckVerdict.fail(
        name,
        'no staged libflutter.so for $abi — engine-extraction must run '
        'before packaging',
      );
    }
    final appCandidates = extractDartSnapshotVersionCandidates(
      await File(libapp).readAsBytes(),
    );
    final engineCandidates = extractDartSnapshotVersionCandidates(
      await File(libflutter).readAsBytes(),
    );
    final common = appCandidates.toSet().intersection(
      engineCandidates.toSet(),
    );
    if (common.length == 1) {
      return ArtifactCheckVerdict.ok(name, 'snapshot ${common.first}');
    }
    if (common.isEmpty) {
      return ArtifactCheckVerdict.fail(
        name,
        'no Dart snapshot version shared between libapp.so '
        '(${appCandidates.join(', ')}) and libflutter.so '
        '(${engineCandidates.join(', ')}) — the engine will reject this '
        'snapshot ("VM snapshot invalid"). Rebuild the AOT against the '
        'engine flutter runs (see '
        'docs/evidence/android-release-engine-pairing-2026-09-27.mdx)',
      );
    }
    return ArtifactCheckVerdict.fail(
      name,
      'ambiguous Dart snapshot version — candidates common to libapp.so and '
      'libflutter.so: ${common.join(', ')}',
    );
  }
}

/// The engine variant packaged into the artifact must match the build mode
/// (debug → debug engine, profile → profile engine, release → release
/// engine). Uses the provenance fact recorded by `engine-extraction`; when
/// the fact is absent (build predating ADR-0029 D1) the check skips — the
/// completeness check is the one that demands the fact.
class EngineVariantMatchesModeCheck implements ArtifactCheck {
  const EngineVariantMatchesModeCheck();

  @override
  String get name => 'engine-variant-matches-mode';

  @override
  Future<ArtifactCheckVerdict> check(
    final ArtifactCheckContext context,
  ) async {
    final variant = context.state.provenanceFacts
        .cast<ProvenanceFact?>()
        .firstWhere(
          (final f) => f!.key == factEngineVariant,
          orElse: () => null,
        )
        ?.value as String?;
    if (variant == null) {
      return ArtifactCheckVerdict.skip(
        name,
        'no engine variant provenance fact — run engine-extraction from '
        'oka >= 0.6.0',
      );
    }
    final expected = engineVariantForMode(context.ctx.mode);
    if (variant == expected) {
      return ArtifactCheckVerdict.ok(name, "variant '$variant'");
    }
    return ArtifactCheckVerdict.fail(
      name,
      "staged engine variant '$variant' does not match build mode "
      "'${context.ctx.mode.name}' (expected '$expected') — a debug JIT "
      'engine in a release APK hangs on the splash forever',
    );
  }
}

/// The record must carry the facts the builtin pipeline promises. A missing
/// fact means an unattested artifact — the exact gap that turned the
/// 2026-09-27 incident into archaeology.
class ProvenanceCompletenessCheck implements ArtifactCheck {
  const ProvenanceCompletenessCheck({
    this.requiredFacts = builtinRequiredFacts,
    this.releaseOnlyFacts = builtinReleaseOnlyFacts,
  });

  /// Facts every attested build must carry.
  final List<String> requiredFacts;

  /// Facts only meaningful in release AOT builds.
  final List<String> releaseOnlyFacts;

  static const builtinRequiredFacts = <String>[
    factEngineVariant,
    factEngineLibflutterSha256,
    factResolutionPackageConfigSha256,
    factAssembleFingerprint,
    'build.mode',
  ];
  static const builtinReleaseOnlyFacts = <String>[
    factAotSnapshotSha256,
    factAotBuildId,
  ];

  @override
  String get name => 'provenance-completeness';

  @override
  Future<ArtifactCheckVerdict> check(
    final ArtifactCheckContext context,
  ) async {
    final record = context.state.provenanceFacts;
    final present = record.map((final f) => f.key).toSet();
    final required = <String>[
      ...requiredFacts,
      if (context.ctx.mode.isRelease) ...releaseOnlyFacts,
    ];
    final missing = required.where((final k) => !present.contains(k)).toList();
    if (missing.isEmpty) {
      return ArtifactCheckVerdict.ok(name, '${present.length} fact(s)');
    }
    return ArtifactCheckVerdict.fail(
      name,
      'missing provenance fact(s): ${missing.join(', ')} — steps that '
      'promise provenance must run before packaging',
    );
  }
}

/// Default checks the builtin pipeline ships (ADR-0029 D2). Third parties
/// add their own by composing [ValidateArtifactStep] with their lists.
const builtinArtifactChecks = <ArtifactCheck>[
  SnapshotEnginePairingCheck(),
  EngineVariantMatchesModeCheck(),
  ProvenanceCompletenessCheck(),
];

/// Runs [checks] over the staged artifact and fails the build on the first
/// failing verdict. Composition-time wiring keeps this before packaging in
/// the default pipelines; a check failure is a red build, not a shipped APK.
class ValidateArtifactStep extends BuildStep {
  ValidateArtifactStep({this.checks = builtinArtifactChecks});

  final List<ArtifactCheck> checks;

  @override
  String get name => 'validate-artifact';

  @override
  Set<Artifact<Object>> get requires => {flutterAssetsDir};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    if (checks.isEmpty) return StepResult.success();
    final context = ArtifactCheckContext(ctx, state);
    final verdicts = <ArtifactCheckVerdict>[];
    for (final check in checks) {
      final verdict = await check.check(context);
      verdicts.add(verdict);
    }
    final failed = verdicts.where((final v) => !v.passed).toList();
    for (final v in verdicts) {
      // Skips are noise in normal builds; show them only when verbose or
      // when something already failed (they may explain why).
      if (v.passed && v.detail.startsWith('no staged AOT') && !ctx.verbose) {
        continue;
      }
      // ignore: avoid_print
      print(v);
    }
    if (failed.isEmpty) {
      // ignore: avoid_print
      print('🧪 artifact validation: ${verdicts.length} check(s) passed');
      return StepResult.success();
    }
    return StepResult.failure(
      'artifact validation failed — refusing to package:\n'
      '${failed.map((final v) => '  $v').join('\n')}',
    );
  }
}

/// Extracts the Dart snapshot build id recorded by the AOT step (a thin
/// helper so verify rungs and checks agree on extraction).
Future<String?> stagedAotBuildId(final PipelineState state) async {
  final abi = state.abis.isEmpty ? 'arm64-v8a' : normalizeAbi(state.abis.first);
  final libapp = state.libappByAbi[normalizeAbi(abi)];
  if (libapp == null || !File(libapp).existsSync()) return null;
  final candidates = extractDartSnapshotVersionCandidates(
    await File(libapp).readAsBytes(),
  );
  return candidates.isEmpty ? null : candidates.first;
}

/// JSON encoding helper shared with verify rungs.
String encodeVerdictLine(final Map<String, Object?> verdict) =>
    jsonEncode(verdict);

/// Relative-path helper re-exported for step diagnostics.
String buildRelative(final String projectPath, final String path) =>
    p.relative(path, from: projectPath);
