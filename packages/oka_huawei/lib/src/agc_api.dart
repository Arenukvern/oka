import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'agc_credentials.dart';

/// AppGallery Connect (AGC) REST endpoints (ADR-0014 P2).
///
/// Base URL is overridable so tests point the client at a fake transport
/// without touching production defaults; the default matches the public
/// AGC publishing API.
@immutable
class AgcEndpoints {
  const AgcEndpoints({this.baseUrl = defaultBaseUrl});

  /// Production AGC publishing API base URL.
  static const String defaultBaseUrl = 'https://connect-api.cloud.huawei.com';

  /// The base URL every endpoint path is resolved against.
  final String baseUrl;

  /// OAuth2 client-credentials token endpoint.
  Uri tokenUrl() => Uri.parse('$baseUrl/api/oauth2/v1/token');

  /// Upload-URL endpoint for an [appId] and file [suffix] (e.g. `aab`).
  Uri uploadUrlUrl({required final String appId, required final String suffix}) =>
      Uri.parse('$baseUrl/api/publish/v2/upload-url')
          .replace(queryParameters: {'appId': appId, 'suffix': suffix});

  /// Submission endpoint.
  Uri submitUrl() => Uri.parse('$baseUrl/api/publish/v2/app-submit');

  /// Debug string: the base URL.
  @override
  String toString() => 'AgcEndpoints($baseUrl)';
}

/// An OAuth2 access token obtained from the AGC token endpoint.
///
/// The token value is a secret: [toString] redacts unconditionally, and the token
/// never enters `PipelineState`, logs, events, or publish plans — it lives
/// only in the upload step's local scope and in `Authorization` headers.
@immutable
class AgcToken {
  const AgcToken({required this.value, required this.expiresInSeconds});

  /// The bearer token value (secret — never log, store, or echo it).
  final String value;

  /// Token lifetime in seconds (AGC `expires_in`).
  final int expiresInSeconds;

  /// Redacting form.
  @override
  String toString() =>
      'AgcToken([redacted], expires in ${expiresInSeconds}s)';

  /// Identity equality — tokens never compare by value (secret hygiene).
  @override
  bool operator ==(final Object other) => identical(this, other);

  /// Identity hash (pairs with the identity equality).
  @override
  int get hashCode => identityHashCode(this);
}

/// An AGC upload session: where to PUT the artifact and the session id the
/// submission references. Neither field is a secret.
@immutable
class AgcUploadSession {
  const AgcUploadSession({required this.uploadUrl, required this.session});

  /// The presigned URL to PUT the artifact bytes to (not a secret).
  final String uploadUrl;

  /// The session id the `app-submit` call references (not a secret).
  final String session;

  /// Debug string: session id (the upload URL is not echoed).
  @override
  String toString() => 'AgcUploadSession(session: $session)';

  /// Field-wise equality (neither field is a secret).
  @override
  bool operator ==(final Object other) =>
      other is AgcUploadSession &&
      other.uploadUrl == uploadUrl &&
      other.session == session;

  /// Hash over both fields.
  @override
  int get hashCode => Object.hash(uploadUrl, session);
}

/// The AGC submission receipt (non-secret identifiers only).
@immutable
class AgcSubmitReceipt {
  const AgcSubmitReceipt({required this.version, required this.submitId});

  /// App version string reported by AGC for this submission.
  final String version;

  /// AGC submission id (useful for support requests / audit trails).
  final String submitId;

  /// Debug string: version and submit id.
  @override
  String toString() =>
      'AgcSubmitReceipt(version: $version, submitId: $submitId)';

  /// Field-wise equality.
  @override
  bool operator ==(final Object other) =>
      other is AgcSubmitReceipt &&
      other.version == version &&
      other.submitId == submitId;

  /// Hash over both fields.
  @override
  int get hashCode => Object.hash(version, submitId);
}

/// Thrown when the AGC REST API returns an error or an unusable response.
///
/// The message names the endpoint, the HTTP status, and the API `ret`
/// code/message — never request bodies, credentials, or tokens (the
/// no-secret-values law, ADR-0014).
class AgcApiException implements Exception {
  AgcApiException({
    required this.operation,
    required this.statusCode,
    this.retCode,
    this.retMessage,
  });

  /// Which client operation failed: `token`, `upload-url`, `upload`,
  /// `submit`.
  final String operation;

  /// HTTP status AGC answered with.
  final int statusCode;

  /// AGC API error code from the response `ret.code` field, if present.
  final String? retCode;

  /// AGC API error message from the response `ret.msg` field, if present.
  final String? retMessage;

  /// Multi-line actionable failure text (HTTP status, AGC ret code/msg,
  /// and the fix).
  @override
  String toString() {
    final b = StringBuffer(
      'AGC $operation failed (HTTP $statusCode',
    );
    if (retCode != null) b.write(', ret.code $retCode');
    b.write(')');
    if (retMessage != null && retMessage!.isNotEmpty) {
      b.write(': $retMessage');
    }
    b.write(
      ' — check the AGC credentials file, the appId, and the artifact '
      '(see the AppGallery Connect publishing docs); the token is fetched '
      'fresh on every run, so simply re-run after fixing',
    );
    return b.toString();
  }
}

/// The AppGallery Connect publishing flow as a client (ADR-0014 P2).
///
/// One upload = four calls, in order:
///
/// 1. **Token** — OAuth2 client-credentials grant against
///    [AgcEndpoints.tokenUrl] with the API-client `client_id` /
///    `client_secret`.
/// 2. **Upload URL** — request a resumable upload session for the artifact
///    suffix (`aab`).
/// 3. **Upload** — `PUT` the artifact bytes to the session's upload URL.
/// 4. **Submit** — submit the release referencing the session.
///
/// The transport ([http.Client]) is injected: production passes a real
/// client, tests pass a fake (`http.testing.MockClient`) — no real network
/// anywhere in tests. No standard-input reads, no credential material in results: secrets
/// stay in local scope and redact on dump.
class AgcClient {
  AgcClient({required this.client, this.endpoints = const AgcEndpoints()});

  /// Injected HTTP transport (production: a real client; tests: fake).
  final http.Client client;

  /// Endpoints the four calls are made against.
  final AgcEndpoints endpoints;

  /// Step 1 — exchange API-client credentials for an access token.
  Future<AgcToken> fetchToken(final AgcCredentials credentials) async {
    final response = await client.post(
      endpoints.tokenUrl(),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'client_credentials',
        'client_id': credentials.clientId,
        'client_secret': credentials.clientSecret,
      },
    );
    if (response.statusCode != 200) {
      throw AgcApiException(
        operation: 'token',
        statusCode: response.statusCode,
        retMessage: _retMessage(response.body),
      );
    }
    final json = _decode(response.body, operation: 'token');
    final token = json['access_token']?.toString() ?? '';
    if (token.isEmpty) {
      throw AgcApiException(
        operation: 'token',
        statusCode: response.statusCode,
        retMessage: 'response contained no access_token',
      );
    }
    return AgcToken(
      value: token,
      expiresInSeconds:
          int.tryParse(json['expires_in']?.toString() ?? '') ?? 0,
    );
  }

  /// Step 2 — request an upload session for the artifact.
  Future<AgcUploadSession> requestUploadSession({
    required final AgcToken token,
    required final String appId,
    required final String suffix,
  }) async {
    final response = await client.post(
      endpoints.uploadUrlUrl(appId: appId, suffix: suffix),
      headers: _auth(token),
    );
    if (response.statusCode != 200) {
      throw AgcApiException(
        operation: 'upload-url',
        statusCode: response.statusCode,
        retMessage: _retMessage(response.body),
      );
    }
    final json = _decode(response.body, operation: 'upload-url');
    final uploadUrl = json['uploadUrl']?.toString() ?? '';
    final session = json['session']?.toString() ?? '';
    if (uploadUrl.isEmpty || session.isEmpty) {
      throw AgcApiException(
        operation: 'upload-url',
        statusCode: response.statusCode,
        retMessage: 'response contained no uploadUrl/session',
      );
    }
    return AgcUploadSession(uploadUrl: uploadUrl, session: session);
  }

  /// Step 3 — upload the artifact bytes to the session's upload URL.
  Future<void> uploadArtifact({
    required final AgcUploadSession session,
    required final List<int> bytes,
    final String contentType = 'application/octet-stream',
  }) async {
    final response = await client.put(
      Uri.parse(session.uploadUrl),
      headers: {
        'content-type': contentType,
        'session': session.session,
      },
      body: bytes,
    );
    if (response.statusCode != 200) {
      throw AgcApiException(
        operation: 'upload',
        statusCode: response.statusCode,
        retMessage: _retMessage(response.body),
      );
    }
  }

  /// Step 4 — submit the release. [payload] is the typed submit body
  /// rendered by the publish step (track, release notes, phase); it must
  /// contain no secret values.
  Future<AgcSubmitReceipt> submit({
    required final AgcToken token,
    required final String appId,
    required final Map<String, dynamic> payload,
  }) async {
    final response = await client.post(
      endpoints.submitUrl(),
      headers: {
        ..._auth(token),
        'content-type': 'application/json',
      },
      body: jsonEncode({'appId': appId, ...payload}),
    );
    if (response.statusCode != 200) {
      throw AgcApiException(
        operation: 'submit',
        statusCode: response.statusCode,
        retMessage: _retMessage(response.body),
      );
    }
    final json = _decode(response.body, operation: 'submit');
    final ret = json['ret'];
    final retCode = ret is Map ? ret['code']?.toString() ?? '' : '';
    if (retCode.isNotEmpty && retCode != '0') {
      throw AgcApiException(
        operation: 'submit',
        statusCode: response.statusCode,
        retCode: retCode,
        retMessage: ret is Map ? ret['msg']?.toString() : null,
      );
    }
    return AgcSubmitReceipt(
      version: json['version']?.toString() ?? '',
      submitId: json['submitId']?.toString() ?? '',
    );
  }

  Map<String, String> _auth(final AgcToken token) =>
      {'authorization': 'Bearer ${token.value}'};

  static Map<String, dynamic> _decode(
    final String body, {
    required final String operation,
  }) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on FormatException {
      throw AgcApiException(
        operation: operation,
        statusCode: 200,
        retMessage: 'response was not valid JSON',
      );
    }
  }

  /// Extracts `ret.msg` from an AGC error body when present (AGC errors
  /// carry `{"ret": {"code": ..., "msg": ...}}`).
  static String? _retMessage(final String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ret'] is Map) {
        final ret = decoded['ret'] as Map<dynamic, dynamic>;
        return '${ret['code']}: ${ret['msg']}';
      }
    } on FormatException {
      // Non-JSON error body (proxy page, HTML) — leave the message off.
    }
    return null;
  }
}
