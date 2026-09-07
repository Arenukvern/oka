import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// OAuth scope for the Google Play Publisher API.
const String androidPublisherScope =
    'https://www.googleapis.com/auth/androidpublisher';

/// Base URL of the Play Publisher API (androidpublisher/v3).
@visibleForTesting
const String androidPublisherBaseUrl =
    'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';

/// Thrown when the Play Publisher API answers with a non-2xx status.
///
/// Carries the method, URL, status, and response body (Google API error
/// payloads are not secret) — never the request body (an AAB upload or a
/// signed JWT assertion).
class PlayApiException implements Exception {
  PlayApiException({
    required this.method,
    required this.url,
    required this.status,
    required this.responseBody,
  });

  final String method;
  final Uri url;
  final int status;
  final String responseBody;

  @override
  String toString() =>
      'Play Publisher API error: $method $url → HTTP $status\n'
      '$responseBody';
}

/// The result of one successful edit flow.
@immutable
class PlayEditResult {
  const PlayEditResult({
    required this.editId,
    required this.versionCode,
  });

  /// Play edit id (`edits.create`).
  final String editId;

  /// Version code assigned by the bundle upload.
  final int versionCode;

  @override
  String toString() => 'PlayEditResult(edit $editId, versionCode '
      '$versionCode)';
}

/// The Play Publisher API **Edits flow** over an injectable `http.Client`.
///
/// Flow (androidpublisher/v3): create edit → upload AAB (`bundles`) →
/// assign the bundle to a track → commit. The client never authenticates —
/// the caller passes an [http.Client] that already carries credentials
/// (in production the googleapis_auth client created from the
/// service-account JSON; in tests a scripted [FakeHttpTransport]-backed
/// client). No network happens unless the injected client performs it.
class PlayPublisherClient {
  PlayPublisherClient({
    required this.client,
    required this.packageName,
  });

  /// HTTP client carrying OAuth credentials (Authorization header).
  final http.Client client;

  /// Target application package name, e.g. `dev.example.app`.
  final String packageName;

  String _editsUrl() => '$androidPublisherBaseUrl/$packageName/edits';

  /// Parses an API JSON response; a wrong shape is an API error, not a
  /// crash — reported via [PlayApiException].
  Map<String, dynamic> _decode(
    final http.Response response, {
    required final String method,
    required final Uri url,
  }) {
    final String bodyText;
    try {
      bodyText = utf8.decode(response.bodyBytes);
    } on FormatException {
      throw PlayApiException(
        method: method,
        url: url,
        status: response.statusCode,
        responseBody: '(non-UTF-8 response body)',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(bodyText);
    } on FormatException {
      throw PlayApiException(
        method: method,
        url: url,
        status: response.statusCode,
        responseBody: '(response body is not JSON)',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw PlayApiException(
        method: method,
        url: url,
        status: response.statusCode,
        responseBody: '(response body is not a JSON object)',
      );
    }
    return decoded;
  }

  Future<http.Response> _send(final http.Request request) async {
    final response = await client.send(request).then(http.Response.fromStream);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PlayApiException(
        method: request.method,
        url: request.url,
        status: response.statusCode,
        responseBody: utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    }
    return response;
  }

  /// `POST /edits` → edit id.
  Future<String> createEdit() async {
    final url = Uri.parse(_editsUrl());
    final response = await _send(http.Request('POST', url));
    final json = _decode(response, method: 'POST', url: url);
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw PlayApiException(
        method: 'POST',
        url: url,
        status: response.statusCode,
        responseBody: 'edits.create returned no "id"',
      );
    }
    return id;
  }

  /// `POST /edits/{editId}/bundles?uploadType=media` with the AAB bytes →
  /// the assigned version code.
  Future<int> uploadAab({
    required final String editId,
    required final String aabPath,
  }) async {
    final bytes = File(aabPath).readAsBytesSync();
    final url = Uri.parse(
      '${_editsUrl()}/$editId/bundles?uploadType=media',
    );
    final response = await _send(
      http.Request('POST', url)
        ..headers['content-type'] = 'application/octet-stream'
        ..bodyBytes = bytes,
    );
    final json = _decode(response, method: 'POST', url: url);
    final raw = json['versionCode'];
    // The API may return the int64 as a number or as a string.
    final versionCode = raw is int
        ? raw
        : raw is String
        ? int.tryParse(raw)
        : null;
    if (versionCode == null) {
      throw PlayApiException(
        method: 'POST',
        url: url,
        status: response.statusCode,
        responseBody: 'bundles.upload returned no "versionCode"',
      );
    }
    return versionCode;
  }

  /// `POST /edits/{editId}/tracks/{track}` — assigns the uploaded bundle
  /// to [track] (e.g. `internal`).
  ///
  /// [userFraction] (0 < x < 1) turns the release into a staged rollout
  /// (`status: inProgress`); without it the release is `completed`.
  Future<void> assignTrack({
    required final String editId,
    required final String track,
    required final int versionCode,
    final double? userFraction,
    final String? releaseName,
  }) async {
    final url = Uri.parse('${_editsUrl()}/$editId/tracks/$track');
    final body = jsonEncode({
      'releases': [
        {
          if (releaseName != null && releaseName.isNotEmpty)
            'name': releaseName,
          'versionCodes': [versionCode.toString()],
          'status': userFraction == null ? 'completed' : 'inProgress',
          'userFraction': ?userFraction,
        },
      ],
    });
    await _send(
      http.Request('POST', url)
        ..headers['content-type'] = 'application/json'
        ..body = body,
    );
  }

  /// `POST /edits/{editId}:commit` — makes the edit live.
  Future<void> commit({required final String editId}) async {
    final url = Uri.parse('${_editsUrl()}/$editId:commit');
    await _send(http.Request('POST', url));
  }

  /// Runs the full Edits flow: create → upload → assign track → commit.
  Future<PlayEditResult> publishAab({
    required final String aabPath,
    required final String track,
    final double? userFraction,
    final String? releaseName,
  }) async {
    final editId = await createEdit();
    final versionCode = await uploadAab(editId: editId, aabPath: aabPath);
    await assignTrack(
      editId: editId,
      track: track,
      versionCode: versionCode,
      userFraction: userFraction,
      releaseName: releaseName,
    );
    await commit(editId: editId);
    return PlayEditResult(editId: editId, versionCode: versionCode);
  }
}
