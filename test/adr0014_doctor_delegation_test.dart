// ADR-0014 P0 — doctor wiring: the secret audit and credential policy are
// parse-and-delegate blocks in the CLI; the mechanics live in oka_core.
//
// Companion to the ADR-0015 platform-leakage gate (same heuristics style):
// the CLI file may parse flags and format returned lines, never implement
// policy.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final cliFile = File(
    p.join(Directory.current.path, 'packages', 'oka', 'lib', 'src', 'cli', 'doctor_command.dart'),
  );
  final source = cliFile.readAsStringSync();

  test('the two ADR-0014 blocks exist and delegate to oka_core', () {
    expect(source, contains("print('[Secret Audit (ADR-0014)]');"));
    expect(source, contains("print('[Credential Policy (ADR-0014)]');"));
    expect(source, contains('doctorSecretAuditLines('));
    expect(source, contains('doctorCredentialPolicyLines('));
    // Parse-and-delegate: raw define flags are extracted, nothing parsed
    // beyond the flag prefix.
    // Both flag spellings with a trailing '=' (value-carrying form).
    expect(source, contains("'--dart-define="));
    expect(source, contains("'--dart-define-from-file="));
  });

  test('no audit/policy mechanics leak into the CLI', () {
    // The secret-pattern list, gitignore matcher, and OKA_* env discovery
    // are oka_core's — the CLI must not redefine or reimplement them.
    expect(source, isNot(contains('secretishKeyPatterns')));
    expect(source, isNot(contains('isSecretishKey')));
    expect(source, isNot(contains('GitignoreChecker')));
    expect(source, isNot(contains('checkCredentialRepoHygiene')));
    // The oka-mechanics env denylist lives in oka_core; the CLI never
    // enumerates OKA_* env vars itself.
    expect(source, isNot(contains("'OKA_")));
    expect(source, isNot(contains('auditDartDefines')));
  });

  test('the [Toolchain Policy] block stays byte-identical', () {
    // ADR-0014 P0 must not disturb the ADR-0013 T1 doctor surface.
    expect(
      source,
      contains("print('[Toolchain Policy (ADR-0013)]');"),
    );
    expect(source, contains('describePolicyLines'));
    expect(source, contains('── Toolchain policy (ADR-0013 T1)'));
    expect(source, contains('── End toolchain policy block'));
  });
}
