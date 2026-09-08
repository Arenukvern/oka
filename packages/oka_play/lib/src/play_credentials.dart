import 'dart:convert';

import 'package:oka_core/oka_core.dart';

/// The credential kind oka_play resolves: a Google Play service-account
/// JSON file (build-host credential, ADR-0014 tier 2 — referenced by
/// *path*, never carried as a value).
const String playServiceAccountKind = 'service-account-json';

/// The [CredentialRef] for the Play service-account JSON (path reference;
/// redacting `toString`, ADR-0014).
///
/// Resolution policy (ordered, via [CredentialResolver]):
/// 1. [explicitPath] — typed config (`PlayPublishTarget.serviceAccountPath`);
/// 2. `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var naming a *path*;
/// 3. `~/.oka/credentials/play/service-account-json`.
CredentialRef playServiceAccountRef({
  final String? explicitPath,
  final String? envVar,
}) =>
    CredentialRef(
      target: 'play',
      kind: playServiceAccountKind,
      explicitPath: explicitPath,
      envVar: envVar,
    );

/// Required fields of a Play service-account JSON file (checked by name
/// only — values are never echoed, logged, or stored).
const Set<String> requiredServiceAccountFields = {
  'type',
  'client_id',
  'client_email',
  'private_key',
};

/// Thrown when a service-account JSON file has the wrong shape. The
/// message names the missing fields — never any value.
class ServiceAccountFormatException implements Exception {
  ServiceAccountFormatException({required this.problem});

  /// Which fields are missing or malformed (names only, never values).
  final String problem;

  /// Error text naming the shape problem.
  @override
  String toString() => 'invalid service-account JSON: $problem';
}

/// Parses and validates the *shape* of a Play service-account JSON file.
///
/// Only the structure is inspected; the returned map carries the values
/// needed for the JWT signing (in memory only — never in
/// [PipelineState], logs, or plans). A wrong shape fails naming the
/// missing fields — values are never echoed.
Map<String, dynamic> parseServiceAccountJson(final String contents) {
  final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } on FormatException catch (e) {
    throw ServiceAccountFormatException(
      problem: 'not valid JSON (${e.message})',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw ServiceAccountFormatException(
      problem: 'top level must be a JSON object',
    );
  }
  final map = Map<String, dynamic>.from(decoded as Map);
  final missing = requiredServiceAccountFields
      .where((final f) => map[f] is! String)
      .toList();
  if (missing.isNotEmpty) {
    throw ServiceAccountFormatException(
      problem: 'missing required field(s): ${missing.join(', ')}',
    );
  }
  if (map['type'] != 'service_account') {
    throw ServiceAccountFormatException(
      problem: '"type" must be "service_account"',
    );
  }
  return map;
}
