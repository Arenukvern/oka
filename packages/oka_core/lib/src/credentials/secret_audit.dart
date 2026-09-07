import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Secret-ish dart-define key patterns (ADR-0014).
///
/// A tested constant, not tribal knowledge: a dart-define key matching any
/// pattern (case-insensitive substring) is a **failure** in the doctor
/// audit. The three-tier model (ADR-0014) treats `--dart-define` /
/// `--dart-define-from-file` values as compiler-baked constants recoverable
/// from the shipped binary — so they must never carry credential contents.
const List<String> secretishKeyPatterns = [
  'password',
  'token',
  'secret',
  'apikey',
  'api_key',
  'private_key',
  'privatekey',
  'client_secret',
];

/// Whether a dart-define [key] is secret-ish (case-insensitive match
/// against [secretishKeyPatterns]).
bool isSecretishKey(final String key) {
  final lower = key.toLowerCase();
  return secretishKeyPatterns.any(lower.contains);
}

/// The ADR-0014 tier-rule remediation message.
const String secretAuditTierRule =
    'ADR-0014 tier rule: dart-defines are baked into the shipped binary '
    '(recoverable from libapp.so, CI logs, and process listings). Move the '
    'value to a credential file and reference the path (typed config, or '
    'an OKA_* env var naming a path).';

/// One audit finding: a dart-define key that looks like a secret.
@immutable
class SecretAuditFinding {
  const SecretAuditFinding({
    required this.key,
    required this.source,
    required this.matchedPattern,
  });

  /// The offending dart-define key (the *key* is reported — never the
  /// value, which is not read at all).
  final String key;

  /// Where the key came from: `'inline'` (`--dart-define`) or
  /// `'file:<name>'` (`--dart-define-from-file`).
  final String source;

  /// The [secretishKeyPatterns] entry that matched.
  final String matchedPattern;

  /// Full, actionable message (audit table + tier rule).
  String get message =>
      'dart-define key "$key" ($source) matches secret-ish pattern '
      '"$matchedPattern". $secretAuditTierRule';
}

/// Audits dart-define keys (inline `--dart-define` + `--dart-define-from-file`
/// keys) against [secretishKeyPatterns]. Pure: takes keys only — values are
/// never read, never stored, never logged (ADR-0014).
///
/// Returns one [SecretAuditFinding] per offending key, inline first, then
/// file keys in file order.
List<SecretAuditFinding> auditDartDefines({
  final Map<String, String> inlineDefines = const {},
  final Map<String, String> fileDefines = const {},
}) => [
      for (final entry in inlineDefines.entries)
        if (isSecretishKey(entry.key))
          SecretAuditFinding(
            key: entry.key,
            source: 'inline',
            matchedPattern:
                secretishKeyPatterns
                .firstWhere(entry.key.toLowerCase().contains),
          ),
      for (final entry in fileDefines.entries)
        if (isSecretishKey(entry.key))
          SecretAuditFinding(
            key: entry.key,
            source: 'file',
            matchedPattern:
                secretishKeyPatterns
                .firstWhere(entry.key.toLowerCase().contains),
          ),
    ];

/// Doctor lines for the secret audit: ✅ when clean, one ❌ line per
/// finding with the tier-rule fix.
List<String> describeSecretAuditLines({
  final Map<String, String> inlineDefines = const {},
  final Map<String, String> fileDefines = const {},
}) {
  final findings = auditDartDefines(
    inlineDefines: inlineDefines,
    fileDefines: fileDefines,
  );
  if (findings.isEmpty) {
    final clean = '✅ no secret-ish dart-define keys '
        '(${inlineDefines.length} inline, ${fileDefines.length} from file) '
        '— dart-defines are for app-visible, non-secret build config only';
    return [clean];
  }
  return [
    for (final f in findings) '❌ ${f.message}',
  ];
}

/// Parse-and-delegate entry for `oka doctor`: parses raw
/// `--dart-define=K=V` flag values and `--dart-define-from-file` paths
/// (the CLI passes raw strings only — no mechanics), audits the keys, and
/// returns doctor lines. Unreadable files become ❌ lines, never throws.
List<String> doctorSecretAuditLines({
  final List<String> inlineDefineArgs = const [],
  final List<String> defineFilePaths = const [],
}) {
  // Keys only — values are never read (the map values are placeholders).
  final inline = <String, String>{
    for (final arg in inlineDefineArgs)
      if (arg.contains('=')) arg.substring(0, arg.indexOf('=')): '',
  };
  final fileKeys = <String, String>{};
  final unreadable = <String>[];
  for (final path in defineFilePaths) {
    try {
      final decoded = jsonDecode(File(path).readAsStringSync());
      if (decoded is! Map) {
        unreadable.add('$path (not a JSON object)');
        continue;
      }
      for (final k in decoded.keys) {
        fileKeys[k.toString()] = '';
      }
    } on FileSystemException {
      unreadable.add(path);
    } on FormatException {
      unreadable.add('$path (invalid JSON)');
    }
  }
  return [
    ...describeSecretAuditLines(
      inlineDefines: inline,
      fileDefines: fileKeys,
    ),
    for (final u in unreadable)
      _unreadableLine(u),
  ];
}

String _unreadableLine(final String u) => '⚠️  --dart-define-from-file could '
    'not be read: $u — fix the path or the file format; its keys were not '
    'audited';
