// ADR-0014 P0 — the doctor secret audit as a pure function (oka_core).
//
// dart-define keys (inline + from-file) are checked against a tested
// constant of secret-ish patterns; a hit is a failure naming the ADR-0014
// tier rule. Values are never read — keys only.
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('secretishKeyPatterns (the tested constant)', () {
    test('every pattern catches a realistic key, case-insensitively', () {
      final table = <String, String>{
        'password': 'DB_PASSWORD',
        'token': 'authToken',
        'secret': 'CLIENT_SECRET',
        'apikey': 'mapsApiKey',
        'api_key': 'STRIPE_API_KEY',
        'private_key': 'signing_private_key',
        'privatekey': 'myPrivateKey',
        'client_secret': 'OAUTH_CLIENT_SECRET',
      };
      expect(
        table.keys.toSet(),
        secretishKeyPatterns.toSet(),
        reason: 'the table must cover every pattern in the constant',
      );
      for (final entry in table.entries) {
        expect(
          isSecretishKey(entry.value),
          isTrue,
          reason: '"${entry.value}" must trip "${entry.key}"',
        );
      }
      // Case-insensitive by construction.
      for (final pattern in secretishKeyPatterns) {
        expect(isSecretishKey(pattern.toUpperCase()), isTrue);
        expect(isSecretishKey(pattern.toLowerCase()), isTrue);
      }
    });

    test('app-visible non-secret config stays clean', () {
      const clean = [
        'API_BASE_URL',
        'FEATURE_NEW_CHECKOUT',
        'BUILD_CHANNEL',
        'FLAVOR_NAME',
        'SENTRY_DSN', // DSNs are debatable but not in the tested list
      ];
      for (final key in clean) {
        expect(isSecretishKey(key), isFalse, reason: key);
      }
    });
  });

  group('auditDartDefines', () {
    test('flags secret-ish inline keys with the tier rule', () {
      final findings = auditDartDefines(
        inlineDefines: {
          'API_BASE_URL': 'https://api.example.com',
          'MY_TOKEN': 'v4lue-x9',
        },
      );
      expect(findings, hasLength(1));
      expect(findings.single.key, 'MY_TOKEN');
      expect(findings.single.source, 'inline');
      expect(findings.single.matchedPattern, 'token');
      expect(findings.single.message, contains('tier rule'));
      expect(findings.single.message, contains('credential file'));
      expect(findings.single.message, contains('reference the path'));
      // The value never appears anywhere in the finding.
      expect(findings.single.message, isNot(contains('v4lue-x9')));
    });

    test('flags secret-ish from-file keys, labeled as file source', () {
      final findings = auditDartDefines(
        fileDefines: {'client_secret_raw': 'x'},
      );
      expect(findings.single.source, 'file');
      // First matching pattern in the constant's order wins.
      expect(findings.single.matchedPattern, 'secret');
    });

    test('clean defines yield zero findings', () {
      expect(
        auditDartDefines(
          inlineDefines: const {'API_BASE_URL': 'x'},
          fileDefines: const {'FEATURE_X': 'true'},
        ),
        isEmpty,
      );
    });
  });

  group('describeSecretAuditLines (doctor format)', () {
    test('clean run prints ✅ with counts', () {
      final lines = describeSecretAuditLines(
        inlineDefines: const {'API_BASE_URL': 'x'},
        fileDefines: const {'FEATURE_X': 'y'},
      );
      expect(lines.single, contains('✅'));
      expect(lines.single, contains('1 inline'));
      expect(lines.single, contains('1 from file'));
    });

    test('each finding is a ❌ line naming key, source, pattern, tier rule',
        () {
      final lines = describeSecretAuditLines(
        inlineDefines: const {'DB_PASSWORD': 'x'},
        fileDefines: const {'PRIVATE_KEY_FILE': 'y'},
      );
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('❌'));
      expect(lines[0], contains('DB_PASSWORD'));
      expect(lines[0], contains('(inline)'));
      expect(lines[0], contains('password'));
      expect(lines[1], contains('PRIVATE_KEY_FILE'));
      expect(lines[1], contains('(file)'));
      expect(lines.join('\n'), contains('ADR-0014'));
    });
  });

  group('doctorSecretAuditLines (parse-and-delegate entry)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_audit_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('parses raw --dart-define args (keys only, values dropped)', () {
      final lines = doctorSecretAuditLines(
        inlineDefineArgs: ['API_BASE_URL=https://x', 'GITHUB_TOKEN=ghp_x'],
      );
      final joined = lines.join('\n');
      expect(joined, contains('GITHUB_TOKEN'));
      expect(joined, isNot(contains('ghp_x')),
          reason: 'values are never echoed by the audit');
      expect(joined, isNot(contains('API_BASE_URL=')));
    });

    test('audits --dart-define-from-file keys without printing values', () {
      final f = File(p.join(tmp.path, 'defines.json'))
        ..writeAsStringSync(jsonEncode({
          'API_BASE_URL': 'https://x',
          'OAUTH_SECRET_VALUE': 'hunter2',
        }));
      final lines = doctorSecretAuditLines(defineFilePaths: [f.path]);
      final joined = lines.join('\n');
      expect(joined, contains('OAUTH_SECRET_VALUE'));
      expect(joined, isNot(contains('hunter2')));
      expect(joined, contains('tier rule'));
    });

    test('unreadable/invalid define files warn, never throw', () {
      final bad = File(p.join(tmp.path, 'bad.json'))
        ..writeAsStringSync('not json');
      final lines = doctorSecretAuditLines(
        defineFilePaths: [
          p.join(tmp.path, 'missing.json'),
          bad.path,
        ],
      );
      final joined = lines.join('\n');
      expect(joined, contains('⚠️'));
      expect(joined, contains('missing.json'));
      expect(joined, contains('invalid JSON'));
    });

    test('empty invocation → clean line', () {
      expect(
        doctorSecretAuditLines().single,
        contains('✅ no secret-ish dart-define keys'),
      );
    });
  });
}
