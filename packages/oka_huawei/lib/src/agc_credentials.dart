import 'dart:convert';

import 'package:meta/meta.dart';

/// Parsed AppGallery Connect API-client credentials (ADR-0014 P2).
///
/// The credential **file** is resolved by path only (a `CredentialRef`
/// `huawei/agconnect-credentials`); this class holds the parsed *contents*
/// and exists solely inside the upload step's local scope: never in
/// `PipelineState`, never in logs, events, or publish plans. [toString]
/// redacts unconditionally — dumping an instance can never leak the secret.
///
/// The expected file is the AppGallery Connect "API client" credential JSON
/// (AppGallery Connect → Users and permissions → API client):
///
/// ```json
/// {
///   "client_id": "123456",
///   "client_secret": "<secret>"
/// }
/// ```
@immutable
class AgcCredentials {
  const AgcCredentials({required this.clientId, required this.clientSecret});

  /// Parses the credential file contents ([raw], UTF-8 JSON). Throws
  /// [FormatException] with an actionable message when required keys are
  /// missing — the message names the *expected keys*, never the values.
  factory AgcCredentials.parse(final String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException(
        'agconnect credentials file is not valid JSON — re-export the '
        'AppGallery Connect API-client credential file',
      );
    }
    if (decoded is! Map) {
      throw const FormatException(
        'agconnect credentials file must contain a JSON object with '
        '"client_id" and "client_secret"',
      );
    }
    final clientId = decoded['client_id']?.toString() ?? '';
    final clientSecret = decoded['client_secret']?.toString() ?? '';
    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw FormatException(
        'agconnect credentials file must contain non-empty "client_id" and '
        '"client_secret" keys (the AppGallery Connect API-client JSON); '
        'found keys: ${decoded.keys.map((final k) => '"$k"').join(', ')}',
      );
    }
    return AgcCredentials(clientId: clientId, clientSecret: clientSecret);
  }

  /// AGC OAuth2 client id (the `client_id` key of the credential JSON).
  final String clientId;

  /// AGC OAuth2 client secret (the `client_secret` key) — a secret value:
  /// never logged, never stored, redacted by [toString].
  final String clientSecret;

  /// Redacting form: contents are a secret — a dump can never leak them.
  @override
  String toString() => 'AgcCredentials(client_id: [redacted], '
      'client_secret: [redacted])';

  @override
  bool operator ==(final Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);
}
