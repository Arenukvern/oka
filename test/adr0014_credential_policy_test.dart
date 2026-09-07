// ADR-0014 P0 — the credential-path resolution policy (oka_core).
//
// Mirrors the T1 tool-policy shape: ordered candidate sources as data,
// resolution results that name every candidate tried and the fix, doctor
// lines, injectable environment for tests.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CredentialRef', () {
    test('derives the OKA_<TARGET>_* env var and well-known path', () {
      const ref = CredentialRef(target: 'play', kind: 'service-account-json');
      expect(ref.envVarName, 'OKA_PLAY_SERVICE_ACCOUNT_JSON');
      expect(
        ref.wellKnownPath,
        '~/.oka/credentials/play/service-account-json',
      );
    });

    test('explicit overrides win over the derived defaults', () {
      const ref = CredentialRef(
        target: 'play',
        kind: 'service-account-json',
        envVar: 'OKA_PLAY_SERVICE_ACCOUNT',
        wellKnownFileName: 'service-account.json',
      );
      expect(ref.envVarName, 'OKA_PLAY_SERVICE_ACCOUNT');
      expect(
        ref.wellKnownPath,
        '~/.oka/credentials/play/service-account.json',
      );
    });

    test('toString redacts the path (ADR-0014 law)', () {
      const ref = CredentialRef(
        target: 'play',
        kind: 'service-account-json',
        explicitPath: 'credentials/super-secret-name.json',
      );
      expect(ref.toString(), isNot(contains('super-secret-name')));
      expect(ref.toString(), contains('play/service-account-json'));
      expect(ref.toString(), contains('[redacted]'));
    });

    test('describe() may show the path for doctor; values never exist', () {
      const ref = CredentialRef(target: 'play', kind: 'sa');
      expect(ref.describe('/tmp/sa.json'), contains('/tmp/sa.json'));
    });
  });

  group('CredentialResolver (injected env)', () {
    late Directory tmp;
    late String home;
    late String project;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_cred_test_');
      home = p.join(tmp.path, 'home');
      project = p.join(tmp.path, 'project');
      Directory(p.join(home, '.oka', 'credentials', 'play'))
          .createSync(recursive: true);
      Directory(project).createSync();
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    CredentialResolver resolver([final Map<String, String> env = const {}]) =>
        CredentialResolver(environment: env, home: home);

    const ref = CredentialRef(target: 'play', kind: 'service-account-json');

    test('policyFor: ordered config → env → well-known, as data', () {
      expect(
        resolver().policyFor(ref).map((final s) => s.kind),
        [CredentialSourceKind.env, CredentialSourceKind.wellKnown],
      );
      expect(
        resolver()
            .policyFor(
              const CredentialRef(
                target: 'play',
                kind: 'sa',
                explicitPath: 'x.json',
              ),
            )
            .map((final s) => s.kind),
        [
          CredentialSourceKind.config,
          CredentialSourceKind.env,
          CredentialSourceKind.wellKnown,
        ],
      );
    });

    test('explicit typed-config path wins', () {
      final explicit = File(
        p.join(project, 'sa.json'),
      )..writeAsStringSync('{}');
      final r = resolver().resolve(
        CredentialRef(
          target: 'play',
          kind: 'sa',
          explicitPath: explicit.path,
        ),
      );
      expect(r.ok, isTrue);
      expect(r.path, explicit.path);
      expect(r.source!.kind, CredentialSourceKind.config);
    });

    test('a missing explicit path fails WITHOUT falling through (hard '
        'boundary, like the tool policy)', () {
      final r = resolver({
        'OKA_PLAY_SA': p.join(home, 'elsewhere.json'),
      }).resolve(
        const CredentialRef(
          target: 'play',
          kind: 'sa',
          explicitPath: 'missing/credential.json',
        ),
      );
      expect(r.ok, isFalse);
      expect(r.problem, contains('missing/credential.json'));
      expect(r.tried.map((final s) => s.kind), [CredentialSourceKind.config]);
    });

    test('OKA_* env var naming an existing path resolves', () {
      final envFile = File(
        p.join(tmp.path, 'env-credential.json'),
      )..writeAsStringSync('{}');
      final r = resolver({
        'OKA_PLAY_SERVICE_ACCOUNT_JSON': envFile.path,
      }).resolve(ref);
      expect(r.ok, isTrue);
      expect(r.path, envFile.path);
      expect(r.source!.qualified, 'env OKA_PLAY_SERVICE_ACCOUNT_JSON');
    });

    test('env var set to a non-path falls through to the well-known '
        'location', () {
      final wellKnown = File(
        p.join(home, '.oka', 'credentials', 'play',
            'service-account-json'),
      )..writeAsStringSync('{}');
      final r = resolver({
        'OKA_PLAY_SERVICE_ACCOUNT_JSON': 'definitely-not-a-path',
      }).resolve(ref);
      expect(r.ok, isTrue);
      expect(r.path, wellKnown.path);
      expect(r.source!.kind, CredentialSourceKind.wellKnown);
    });

    test('~ inside the env var expands against the injected home', () {
      Directory(p.join(home, 'creds')).createSync();
      final envFile = File(
        p.join(home, 'creds', 'sa.json'),
      )..writeAsStringSync('{}');
      final r = resolver({
        'OKA_PLAY_SERVICE_ACCOUNT_JSON': '~/creds/sa.json',
      }).resolve(ref);
      expect(r.ok, isTrue);
      expect(r.path, envFile.path);
    });

    test('well-known location resolves last', () {
      final wellKnown = File(
        p.join(home, '.oka', 'credentials', 'play',
            'service-account-json'),
      )..writeAsStringSync('{}');
      final r = resolver().resolve(ref);
      expect(r.ok, isTrue);
      expect(r.path, wellKnown.path);
    });

    test('failure names every candidate tried and the fix', () {
      final r = resolver().resolve(ref);
      expect(r.ok, isFalse);
      // Only probed candidates are listed (the unset env var is not one).
      expect(r.tried.map((final s) => s.kind).toList(),
          [CredentialSourceKind.wellKnown]);
      expect(r.problem, isNotNull);
      // An env var set to a nonexistent path IS probed → listed.
      final probed = resolver({
        'OKA_PLAY_SERVICE_ACCOUNT_JSON': '/nowhere/sa.json',
      }).resolve(ref);
      expect(probed.tried.map((final s) => s.kind).toList(),
          [CredentialSourceKind.env, CredentialSourceKind.wellKnown]);
      // Same remediation law as tools: the exception lists the fix.
      expect(
        () => resolver({
          'OKA_PLAY_SERVICE_ACCOUNT_JSON': '/nowhere/sa.json',
        }).require(ref),
        throwsA(
          isA<CredentialResolutionException>()
              .having(
                (final e) => e.toString(),
                'message',
                allOf(
                  contains('Tried (in order)'),
                  contains('env OKA_PLAY_SERVICE_ACCOUNT_JSON'),
                  contains('wellKnown ~/.oka/credentials/play/'),
                  contains('Fix:'),
                ),
              ),
        ),
      );
    });

    test('remediationFor says path, never value', () {
      final fix = CredentialResolver.remediationFor(ref);
      expect(fix, contains(ref.wellKnownPath));
      expect(fix, contains(ref.envVarName));
      expect(fix, contains('never a value'));
    });

    test('describePolicyLines: doctor-ready ✅/❌ with tried + fix', () {
      File(
        p.join(home, '.oka', 'credentials', 'play',
            'service-account-json'),
      ).writeAsStringSync('{}');
      final lines = resolver().describePolicyLines([ref]);
      expect(lines.first, startsWith('✅ play/service-account-json'));
      expect(lines.join('\n'), contains('source: wellKnown'));

      final missing = resolver({
        'OKA_HUAWEI_AGCONNECT_CREDS': '/nowhere/creds.json',
      }).describePolicyLines([
        const CredentialRef(target: 'huawei', kind: 'agconnect-creds'),
      ]);
      expect(missing.first, startsWith('❌ huawei/agconnect-creds'));
      final joined = missing.join('\n');
      expect(joined, contains('tried 1:'));
      expect(joined, contains('tried 2:'));
      expect(joined, contains('fix:'));
      // Paths only — never contents (there are none to leak, by contract).
      expect(joined, isNot(contains('{}')));
    });
  });

  group('doctorCredentialPolicyLines', () {
    late Directory tmp;
    late String home;
    late String project;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_cred_doctor_');
      home = p.join(tmp.path, 'home');
      project = p.join(tmp.path, 'project');
      Directory(p.join(home, '.oka', 'credentials', 'play'))
          .createSync(recursive: true);
      Directory(project).createSync();
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('prints the policy template and env discovery', () {
      final lines = doctorCredentialPolicyLines(
        environment: const {
          'OKA_PLAY_SERVICE_ACCOUNT_JSON': '/does/not/exist.json',
        },
        home: home,
        projectPath: project,
      );
      final joined = lines.join('\n');
      expect(joined, contains('typed config → OKA_<TARGET>_* env var'));
      expect(joined, contains('a *path*, never a value'));
      expect(
        joined,
        contains('❌ play/service_account_json: not found'),
      );
      // OKA_CACHE et al. are mechanics, not credentials — never discovered.
      final mechanics = doctorCredentialPolicyLines(
        environment: const {
          'OKA_CACHE': '/tmp/cache',
          'OKA_ANDROID_SDK': '/tmp/sdk',
        },
        home: home,
        projectPath: project,
      );
      expect(
        mechanics.join('\n'),
        isNot(contains('OKA_CACHE')),
        reason: 'nonCredentialOkaEnvVars must be excluded from discovery',
      );
    });

    test('repo hygiene: resolved credential inside the project must be '
        'gitignored', () {
      final credDir = Directory(
        p.join(project, 'credentials'),
      )..createSync();
      final sa = File(p.join(credDir.path, 'sa.json'))..writeAsStringSync('{}');
      // Not gitignored → ⚠️.
      var lines = doctorCredentialPolicyLines(
        environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': sa.path},
        home: home,
        projectPath: project,
      );
      expect(
        lines.join('\n'),
        contains('is NOT gitignored'),
        reason: 'ADR-0014: a credential file inside the repo must be '
            'gitignored',
      );
      // Gitignored → ✅.
      File(p.join(project, '.gitignore'))
          .writeAsStringSync('credentials/\n');
      lines = doctorCredentialPolicyLines(
        environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': sa.path},
        home: home,
        projectPath: project,
      );
      expect(
        lines.join('\n'),
        contains('is gitignored'),
      );
    });

    test('well-known location state and legacy value-vars note', () {
      File(
        p.join(home, '.oka', 'credentials', 'play', 'sa.json'),
      ).writeAsStringSync('{}');
      final lines = doctorCredentialPolicyLines(
        environment: const {
          'OKA_STORE_PASS': 'hunter2',
          'OKA_KEY_PASS': 'hunter3',
        },
        home: home,
        projectPath: project,
      );
      final joined = lines.join('\n');
      expect(joined, contains('~/.oka/credentials/play/ has 1 credential'));
      expect(joined, contains('OKA_STORE_PASS / OKA_KEY_PASS carry values'));
      // The legacy note names the vars, never their values.
      expect(joined, isNot(contains('hunter2')));
    });
  });

  group('repo hygiene (ADR-0014)', () {
    test('matchesGitignorePattern table', () {
      // Unanchored: matches the basename at any depth.
      expect(matchesGitignorePattern('*.json', 'credentials/sa.json'), isTrue);
      expect(matchesGitignorePattern('sa.json', 'a/b/sa.json'), isTrue);
      expect(matchesGitignorePattern('*.json', 'lib/main.dart'), isFalse);
      // Anchored by inner slash: root-relative only.
      expect(matchesGitignorePattern('credentials/sa.json', 'x/sa.json'),
          isFalse);
      expect(
        matchesGitignorePattern('credentials/sa.json', 'credentials/sa.json'),
        isTrue,
      );
      // Leading slash anchors; trailing slash is directory-only.
      expect(matchesGitignorePattern('/secrets/', 'secrets/k.json'), isTrue);
      expect(matchesGitignorePattern('/secrets/', 'a/secrets/k.json'), isFalse);
      // Globs.
      expect(matchesGitignorePattern('a/**/b', 'a/x/y/b'), isTrue);
      expect(matchesGitignorePattern('a/**/b', 'a/b'), isTrue);
      expect(matchesGitignorePattern('a/**/b', 'a/x/c'), isFalse);
      expect(matchesGitignorePattern('k?y.json', 'key.json'), isTrue);
      expect(matchesGitignorePattern('k?y.json', 'kxy.json'), isTrue);
    });

    test('isIgnoredByGitignore over a real .gitignore (negation, dirs)', () {
      final tmp = Directory.systemTemp.createTempSync('oka_gitignore_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, '.gitignore')).writeAsStringSync([
        '# comment',
        'credentials/',
        '!credentials/keep.json',
        '*.keystore',
      ].join('\n'));
      final inside = p.join(tmp.path, 'credentials', 'sa.json');
      final negated = p.join(tmp.path, 'credentials', 'keep.json');
      final keystore = p.join(tmp.path, 'upload.keystore');
      final outside = p.join(tmp.path, 'lib', 'main.dart');
      expect(isIgnoredByGitignore(inside, projectPath: tmp.path), isTrue);
      expect(isIgnoredByGitignore(negated, projectPath: tmp.path), isFalse);
      expect(isIgnoredByGitignore(keystore, projectPath: tmp.path), isTrue);
      expect(isIgnoredByGitignore(outside, projectPath: tmp.path), isFalse);
    });

    test('checkCredentialRepoHygiene: fail-closed inside, trivial outside, '
        'seam injectable', () {
      // Seam injected: the checker decides.
      final inside = checkCredentialRepoHygiene(
        credentialPath: '/proj/credentials/sa.json',
        projectPath: '/proj',
        isIgnored: (final path) => path.endsWith('sa.json'),
      );
      expect(inside.ok, isTrue);
      expect(inside.insideProject, isTrue);
      final tracked = checkCredentialRepoHygiene(
        credentialPath: '/proj/credentials/sa.json',
        projectPath: '/proj',
        isIgnored: (final path) => false,
      );
      expect(tracked.ok, isFalse);
      expect(tracked.message, contains('.gitignore'));
      expect(tracked.message, contains('ADR-0014'));
      // Outside the project: not this repo's problem.
      final outside = checkCredentialRepoHygiene(
        credentialPath: '/home/user/.oka/credentials/play/sa.json',
        projectPath: '/proj',
        isIgnored: (final path) => false,
      );
      expect(outside.ok, isTrue);
      expect(outside.insideProject, isFalse);
      expect(
        outside.doctorLine.startsWith('ℹ️'),
        isTrue,
        reason: 'outside-project credentials are informational, not a '
            'warning',
      );
    });

    test('nonCredentialOkaEnvVars is a tested constant', () {
      // The mechanics oka itself defines must never be mistaken for
      // credential path references.
      for (final v in nonCredentialOkaEnvVars) {
        expect(v, startsWith('OKA_'));
      }
      expect(nonCredentialOkaEnvVars, contains('OKA_CACHE'));
      expect(nonCredentialOkaEnvVars, contains('OKA_ANDROID_SDK'));
    });
  });
}
