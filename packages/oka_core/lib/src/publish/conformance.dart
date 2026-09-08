import 'dart:io';

import 'package:meta/meta.dart';

import '../config/build_context.dart';
import '../credentials/credential_ref.dart';
import '../credentials/secret_audit.dart';
import '../pipeline/pipeline.dart';
import '../targets/describe.dart';
import 'publish_target.dart';

/// Marker regexes for the no-stdin law (ADR-0013, inherited by ADR-0014).
///
/// A target's Dart sources must not read stdin in any build path: no
/// `stdin` reference, no line-reader prompts. This is a source-level
/// contract — the same shape as the ADR-0015 CLI platform-leakage gate.
final RegExp stdinUsagePattern = RegExp(r'\bstdin\b|readLineSync|readByteSync');

/// Audits a [PublishTarget] against the three publishing conformance laws
/// (ADR-0014) and returns human-readable violations (empty = conforming).
///
/// The laws:
///
/// 1. **Dry-run without credentials succeeds** — [PublishTarget.dryRun]
///    compiles to a *valid* pipeline, runs with an empty [PipelineState]
///    (no credentials, no tools), and produces a [PublishPlan] describing
///    exactly what a real run would do — endpoint, track, artifact,
///    metadata — without executing any upload.
/// 2. **No stdin, ever** — asserted over [sourcePaths]: every `.dart` file
///    (or directory of files) the target package ships is scanned for
///    [stdinUsagePattern]. Pass the package's `lib/src` directory (and the
///    target's own test file, if it scripts I/O there).
/// 3. **No secret values in state** — after the dry-run run, every
///    [PipelineState] key must be non-secret-ish (per
///    [secretishKeyPatterns]); values must be refs ([CredentialRef]),
///    booleans, numbers, plans ([PublishPlan]), or plain path/id strings —
///    and every credential must appear only in redacted form.
///
/// Pure with respect to the real world: only the dry-run pipeline runs,
/// and the dry-run law forbids it from doing anything.
Future<List<String>> auditPublishConformance(
  final PublishTarget target,
  final BuildContext ctx, {
  final List<String> sourcePaths = const [],
}) async {
  final violations = <String>[];

  // ── Law 1: dry-run without credentials compiles, validates, plans ──
  final chain = describeTarget(target, ctx);
  if (!chain.isValid) {
    violations.add(
      'law 1 (dry-run): target "${target.name}" does not compile to a '
      'valid pipeline: ${chain.validationError}',
    );
    return violations; // the other laws cannot be evaluated on a broken chain
  }
  if (chain.steps.isEmpty) {
    violations.add(
      'law 1 (dry-run): target "${target.name}" compiles to an empty '
      'pipeline — a publish target must describe its run',
    );
  }

  PipelineState? dryRunState;
  if (target.dryRun) {
    // Determinism/purity: compiling twice yields the same step chain.
    final secondCompile = describeTarget(target, ctx);
    final firstNames = chain.steps.map((final s) => s.name).toList();
    final secondNames = secondCompile.steps.map((final s) => s.name).toList();
    if (firstNames.join('|') != secondNames.join('|') ||
        chain.validationError != secondCompile.validationError) {
      violations.add(
        'law 1 (dry-run): compile() is not pure — two compiles produced '
        'different step chains',
      );
    }

    // Run with an empty state: no credentials, no resolved tools.
    final state = PipelineState();
    final pipeline = Pipeline(target.compile(ctx));
    final result = await pipeline.run(ctx, initialState: state);
    if (!result.ok) {
      violations.add(
        'law 1 (dry-run): the dry-run pipeline failed without credentials: '
        '${result.error}',
      );
    }
    final plan = state[PublishPlanStep.plan.id];
    if (plan is! PublishPlan) {
      violations.add(
        'law 1 (dry-run): the pipeline did not produce a publish plan '
        '(artifact "${PublishPlanStep.plan.id}")',
      );
    } else {
      final lines = plan.describeLines().join('\n');
      for (final required in {
        'endpoint: ${target.endpoint}',
        'track: ${target.track}',
        'artifact: ${target.artifactId}',
        for (final k in target.metadata.keys) 'metadata.$k:',
      }) {
        if (!lines.contains(required)) {
          violations.add(
            'law 1 (dry-run): the plan does not describe "$required" — a '
            'dry-run plan must say exactly what a real run would do',
          );
        }
      }
      // Redaction: credentials may appear only via CredentialRef.toString.
      for (final ref in target.credentialRefs) {
        final explicit = ref.explicitPath;
        if (explicit != null && lines.contains(explicit)) {
          violations.add(
            'law 3 (no secret values): the publish plan leaks the explicit '
            'credential path "$explicit" — credential refs must render in '
            'redacted form ($ref)',
          );
        }
      }
      // Directory-artifact convention (ADR-0016 §2): a target declaring
      // artifactIsDirectory must produce a plan that says so, and — when
      // the artifact path exists on disk (the suite runs against a real
      // path) — the path must BE a directory, never a file. A missing path
      // is fine: the dry-run law forbids requiring a produced build.
      if (target.artifactIsDirectory) {
        if (!plan.artifactIsDirectory) {
          violations.add(
            'directory-artifact convention: target "${target.name}" '
            'declares artifactIsDirectory but its plan does not report the '
            'artifact as a directory',
          );
        }
        final artifactType = FileSystemEntity.typeSync(plan.artifactPath);
        if (artifactType == FileSystemEntityType.file) {
          violations.add(
            'directory-artifact convention: target "${target.name}" '
            'declares a directory artifact but "${plan.artifactPath}" is '
            'a file — artifactPath must reference a directory',
          );
        }
      } else {
        final artifactType = FileSystemEntity.typeSync(plan.artifactPath);
        if (artifactType == FileSystemEntityType.directory) {
          violations.add(
            'directory-artifact convention: target "${target.name}" does '
            'not declare artifactIsDirectory but "${plan.artifactPath}" '
            'is a directory — declare the convention so consumers know the '
            'artifact kind (ADR-0016 §2)',
          );
        }
      }
    }
    dryRunState = state;
  }

  // ── Law 2: no stdin in any build path ──
  violations.addAll(_auditNoStdin(sourcePaths));

  // ── Law 3: no secret values in PipelineState ──
  final state = dryRunState;
  if (state != null) {
    for (final entry in state.snapshot.entries) {
      if (isSecretishKey(entry.key)) {
        violations.add(
          'law 3 (no secret values): state key "${entry.key}" matches a '
          'secret-ish pattern — only credential refs and booleans may '
          'enter PipelineState (ADR-0014)',
        );
      }
      final value = entry.value;
      final allowed = value == null ||
          value is bool ||
          value is num ||
          value is String ||
          value is CredentialRef ||
          value is PublishPlan;
      if (!allowed) {
        violations.add(
          'law 3 (no secret values): state key "${entry.key}" holds a '
          '${value.runtimeType} — only refs, booleans, numbers, plans, and '
          'path/id strings may enter PipelineState (ADR-0014)',
        );
      }
    }
  }

  return violations;
}

/// Scans [sourcePaths] (files or directories, `.dart` files) for stdin
/// usage — the mechanical form of the no-stdin law.
List<String> _auditNoStdin(final List<String> sourcePaths) {
  final violations = <String>[];
  for (final path in sourcePaths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      violations.add('law 2 (no stdin): source path not found: $path');
      continue;
    }
    final files = type == FileSystemEntityType.directory
        ? Directory(path)
            .listSync(recursive: true)
            .whereType<File>()
            .where((final f) => f.path.endsWith('.dart'))
            .toList()
        : [File(path)];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (stdinUsagePattern.hasMatch(lines[i])) {
          violations.add(
            'law 2 (no stdin): ${file.path}:${i + 1} references stdin — '
            'build paths never read stdin (ADR-0013 law, inherited by '
            'ADR-0014)',
          );
        }
      }
    }
  }
  return violations;
}

/// Asserts the three ADR-0014 publishing conformance laws for [target] —
/// the shared suite any publish target must pass (the exportable seam
/// target packages call from their tests).
///
/// Pass [sourcePaths] for the no-stdin law: the target package's `lib/src`
/// directory (plus this test file, if it scripts fake tools there).
///
/// ```dart
/// test('publish-play conforms (ADR-0014)', () async {
///   await expectPublishConformance(
///     const PlayPublishTarget(dryRun: true),
///     _ctx(),
///     sourcePaths: ['packages/oka_play/lib/src'],
///   );
/// });
/// ```
Future<void> expectPublishConformance(
  final PublishTarget target,
  final BuildContext ctx, {
  final List<String> sourcePaths = const [],
}) async {
  final violations =
      await auditPublishConformance(target, ctx, sourcePaths: sourcePaths);
  if (violations.isNotEmpty) {
    throw PublishConformanceException(
      target: target.name,
      violations: List.unmodifiable(violations),
    );
  }
}

/// Thrown by [expectPublishConformance] when a publish target violates an
/// ADR-0014 conformance law. Escaping a test, this fails it with the full
/// violation list — no test-framework dependency needed in oka_core.
class PublishConformanceException implements Exception {
  PublishConformanceException({
    required this.target,
    required this.violations,
  });

  final String target;
  final List<String> violations;

  @override
  String toString() =>
      'publish target "$target" violates the ADR-0014 publishing '
      'conformance laws:\n${violations.map((final v) => '  - $v').join('\n')}';
}

/// A conformance fixture: the minimal [PublishTarget] target packages
/// extend, with a pure staging step standing in for real build steps.
///
/// Used by the oka_core conformance tests to prove the laws are checkable
/// end-to-end without any platform package.
@visibleForTesting
class FixturePublishTarget extends PublishTarget {
  const FixturePublishTarget({
    this.dryRunOverride = true,
    this.missingArtifact = false,
    this.polluteState = false,
  });

  final bool dryRunOverride;
  final bool missingArtifact;

  /// Makes the staging step write a secret-ish state key and a non-allowed
  /// value type — for asserting law 3 catches violations.
  final bool polluteState;

  /// Stands in for a real credential reference (path never exists).
  static const serviceAccount = CredentialRef(
    target: 'fixture',
    kind: 'service-account-json',
    explicitPath: 'credentials/fixture-sa.json',
  );

  @override
  String get name => 'publish-fixture';

  @override
  String get description => 'Fixture publish target for conformance tests';

  @override
  bool get dryRun => dryRunOverride;

  @override
  String get endpoint => 'Fake Publisher API v1';

  @override
  String get track => 'internal';

  @override
  String get artifactId => 'aab-path';

  @override
  Map<String, String> get metadata => const {
        'versionName': '1.2.3',
        'releaseNotes': 'whatsnew.txt',
      };

  @override
  List<CredentialRef> get credentialRefs => const [serviceAccount];

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) =>
      missingArtifact ? const [] : [FixtureStageAabStep(pollute: polluteState)];

  @override
  BuildStep uploadStep(final BuildContext ctx) => FixtureUploadStep();
}

/// Pure staging step: provides the fixture artifact id, no I/O.
@visibleForTesting
class FixtureStageAabStep extends BuildStep {
  FixtureStageAabStep({this.pollute = false});

  /// When true, writes law-3 violations into state (secret-ish key + a
  /// map value) — used to prove the audit catches them.
  final bool pollute;

  static const aab = Artifact<String>('aab-path');

  @override
  String get name => 'fixture-stage-aab';

  @override
  Set<Artifact<Object>> get provides => {aab};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    state[aab.id] = '${ctx.buildDir}/app-release.aab';
    if (pollute) {
      state['client_secret'] = 'value';
      state['extra'] = <String, String>{'k': 'v'};
    }
    return Future<StepResult>.value(StepResult.success());
  }
}

/// The real-mode upload tail (never executed under conformance — the audit
/// only compiles/validates non-dry-run targets; it must never run this).
@visibleForTesting
class FixtureUploadStep extends BuildStep {
  FixtureUploadStep();

  static const aab = Artifact<String>('aab-path');

  @override
  String get name => 'fixture-upload';

  @override
  Set<Artifact<Object>> get requires => {aab};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    // A real target would upload here. The conformance audit must never
    // reach this step: it runs only dry-run pipelines.
    throw StateError('the conformance audit executed a real upload step');
  }
}
