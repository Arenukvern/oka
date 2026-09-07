// ADR-0014 P0 — the PublishTarget contract and the publishing conformance
// suite (oka_core).
//
// The three laws: (1) dry-run without credentials compiles, validates, and
// plans without executing uploads; (2) no stdin in any build path; (3) no
// secret values in PipelineState — only credential refs and booleans.
// Proven end-to-end over the FixturePublishTarget; target packages (P1
// oka_play, P2 oka_huawei) assert the same laws via
// `expectPublishConformance`.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildContext _ctx(final Directory tmp) => BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(tmp.path, '.oka_cache'),
      tempDir: p.join(tmp.path, '.oka_cache', 'build', 'debug', 'temp'),
    );

/// Writes Dart sources for the law-2 (no-stdin) scan: [violating] adds a
/// file that reads stdin.
Directory _sourceDir(final Directory tmp, {final bool violating = false}) {
  final dir = Directory(p.join(tmp.path, 'lib', 'src'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'clean.dart')).writeAsStringSync('''
// A target step: pure, no interactive anything.
void doPublish() {}
''');
  if (violating) {
    File(p.join(dir.path, 'bad.dart')).writeAsStringSync('''
import 'dart:io';
void prompt() {
  stdin.readLineSync(); // interactive — forbidden in any build path
}
''');
  }
  return dir;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_publish_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('law 1 — dry-run without credentials', () {
    test('dry-run target compiles to a valid pipeline', () {
      const target = FixturePublishTarget();
      final ctx = _ctx(tmp);
      final chain = describeTarget(target, ctx);
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['fixture-stage-aab', 'publish-plan'],
        reason: 'the upload tail is substituted by the plan step (as code)',
      );
    });

    test('the dry-run plan describes exactly what a real run would do',
        () async {
      const target = FixturePublishTarget();
      final ctx = _ctx(tmp);
      final pipeline = Pipeline(target.compile(ctx));
      final state = PipelineState();
      final result = await pipeline.run(ctx, initialState: state);

      expect(result.ok, isTrue, reason: result.error);
      final plan = state[PublishPlanStep.plan.id] as PublishPlan?;
      expect(plan, isNotNull);
      final lines = plan!.describeLines();
      final joined = lines.join('\n');
      expect(joined, contains('endpoint: Fake Publisher API v1'));
      expect(joined, contains('track: internal'));
      expect(joined, contains('artifact: aab-path'));
      expect(joined, contains('metadata.versionName: 1.2.3'));
      expect(joined, contains('dry run — nothing was uploaded'));
      // Credentials appear only in redacted form.
      expect(
        joined,
        contains(
          'credential: ${FixturePublishTarget.serviceAccount}',
        ),
      );
      expect(
        joined,
        isNot(contains('credentials/fixture-sa.json')),
        reason: 'the plan must not leak the explicit credential path',
      );
    });

    test('the plan runs with an empty state — no credentials, no tools, '
        'no uploads', () async {
      const target = FixturePublishTarget();
      final ctx = _ctx(tmp);
      final result = await Pipeline(target.compile(ctx)).run(ctx);
      expect(result.ok, isTrue, reason: result.error);
    });

    test('a missing publish artifact fails validation before any run', () {
      const target = FixturePublishTarget(missingArtifact: true);
      final ctx = _ctx(tmp);
      final chain = describeTarget(target, ctx);
      expect(chain.isValid, isFalse);
      expect(chain.validationError, contains('aab-path'));
    });

    test('real-mode targets compile + validate but are NEVER executed by '
        'the audit', () async {
      // The real-mode upload step throws if executed — proving the audit
      // never runs a real upload.
      const target = FixturePublishTarget(dryRunOverride: false);
      final ctx = _ctx(tmp);
      final violations = await auditPublishConformance(target, ctx);
      expect(violations, isEmpty);
    });

    test('PublishPlan round-trips through JSON (machine mode)', () {
      const target = FixturePublishTarget();
      final ctx = _ctx(tmp);
      final plan = target.plan(ctx, artifactPath: '/build/app.aab');
      final restored = PublishPlan.fromJson(
        (plan.toJson() as Map<dynamic, dynamic>).cast<String, dynamic>(),
      );
      expect(restored, plan);
    });
  });

  group('law 2 — no stdin in any build path', () {
    test('clean sources pass', () async {
      final dir = _sourceDir(tmp);
      const target = FixturePublishTarget();
      final violations = await auditPublishConformance(
        target,
        _ctx(tmp),
        sourcePaths: [dir.path],
      );
      expect(violations.where((final v) => v.contains('law 2')), isEmpty);
    });

    test('a step reading stdin is named with file and line', () async {
      final dir = _sourceDir(tmp, violating: true);
      final violations = await auditPublishConformance(
        const FixturePublishTarget(),
        _ctx(tmp),
        sourcePaths: [dir.path],
      );
      final law2 = violations.where((final v) => v.contains('law 2')).toList();
      expect(law2, hasLength(1));
      expect(law2.single, contains('bad.dart'));
      expect(law2.single, contains('build paths never read stdin'));
    });

    test('missing source paths are reported, not silently skipped',
        () async {
      final violations = await auditPublishConformance(
        const FixturePublishTarget(),
        _ctx(tmp),
        sourcePaths: [p.join(tmp.path, 'nope')],
      );
      expect(violations.single, contains('law 2'));
      expect(violations.single, contains('not found'));
    });
  });

  group('law 3 — no secret values in state', () {
    test('dry-run state holds only plans and path strings', () async {
      const target = FixturePublishTarget();
      final ctx = _ctx(tmp);
      final state = PipelineState();
      await Pipeline(target.compile(ctx)).run(ctx, initialState: state);
      for (final entry in state.snapshot.entries) {
        expect(
          isSecretishKey(entry.key),
          isFalse,
          reason: 'state key "${entry.key}" looks like a secret',
        );
      }
      expect(state.snapshot['publish-plan'], isA<PublishPlan>());
    });

    test('the audit catches a secret-ish state key and a non-allowed '
        'value type', () async {
      final violations = await auditPublishConformance(
        const FixturePublishTarget(polluteState: true),
        _ctx(tmp),
      );
      final law3 = violations.where((final v) => v.contains('law 3')).toList();
      expect(
        law3.join('\n'),
        allOf(
          contains('client_secret'),
          contains('Map'),
          contains('only credential refs and booleans'),
        ),
      );
    });

    test('CredentialRef toString redacts wherever state is dumped', () {
      const ref = FixturePublishTarget.serviceAccount;
      expect(ref.toString(), contains('[redacted]'));
      expect(ref.toString(), isNot(contains('credentials/')));
    });
  });

  group('expectPublishConformance (the exportable seam)', () {
    test('a conforming dry-run target passes the full suite', () async {
      final dir = _sourceDir(tmp);
      await expectPublishConformance(
        const FixturePublishTarget(),
        _ctx(tmp),
        sourcePaths: [dir.path],
      );
    });

    test('a non-conforming target fails naming the law', () async {
      final dir = _sourceDir(tmp, violating: true);
      await expectLater(
        expectPublishConformance(
          const FixturePublishTarget(missingArtifact: true),
          _ctx(tmp),
          sourcePaths: [dir.path],
        ),
        throwsA(
          isA<PublishConformanceException>()
              .having(
                (final e) => e.target,
                'target',
                'publish-fixture',
              )
              .having(
                (final e) => e.toString(),
                'message',
                allOf(
                  contains('law 1 (dry-run)'),
                  contains('aab-path'),
                ),
              ),
        ),
      );
    });
  });

  group('PublishTarget contract shape', () {
    test('names are lowercase identifiers, never reserved verbs', () {
      expect(validateTargetName(const FixturePublishTarget().name), isNull);
    });

    test('dryRun is part of the typed config surface', () {
      expect(const FixturePublishTarget().dryRun, isTrue);
      expect(const FixturePublishTarget(dryRunOverride: false).dryRun,
          isFalse);
    });

    test('toString marks dry-run targets', () {
      expect(const FixturePublishTarget().toString(),
          'PublishTarget(publish-fixture [dry-run])');
    });
  });
}
