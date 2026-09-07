import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// One request recorded by a [FakeHttpTransport].
///
/// Tests assert over [method], [url], and [body] to prove the *exact* HTTP
/// conversation a step performs — offline, deterministic, and ordered.
@immutable
class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// Request body as bytes (binary uploads such as AABs stay byte-exact).
  final List<int> body;

  /// Body decoded as UTF-8 text (for JSON requests).
  String get bodyText => utf8.decode(body);

  /// Body decoded as JSON (for JSON requests).
  Object? get bodyJson => jsonDecode(bodyText);

  @override
  String toString() => '$method $url (${body.length} bytes)';
}

/// A scripted reply: status, headers, and body bytes.
@immutable
class ScriptedResponse {
  const ScriptedResponse({
    this.status = 200,
    this.headers = const {'content-type': 'application/json; charset=utf-8'},
    this.json,
    this.body,
    this.bytes,
  });

  /// HTTP status code to answer with (default 200).
  final int status;

  /// Response headers (defaults to an `application/json` content type).
  final Map<String, String> headers;

  /// JSON body (mutually exclusive with [body]/[bytes]).
  final Object? json;

  /// Raw text body (mutually exclusive with [json]/[bytes]).
  final String? body;

  /// Raw byte body, for binary responses (mutually exclusive with the
  /// other body fields).
  final List<int>? bytes;

  /// The response payload as bytes: explicit bytes, then text, then JSON.
  List<int> get payload {
    if (bytes != null) return bytes!;
    if (body != null) return utf8.encode(body!);
    return utf8.encode(jsonEncode(json ?? {}));
  }
}

/// Handler for one routed request.
typedef FakeRouteHandler = ScriptedResponse Function(
  RecordedRequest request,
);

/// A scripted, recording `http.Client` — the offline transport for any
/// target-package test (ADR-0014 conformance: no real network, ever).
///
/// Requests are recorded in order and dispatched to routes by URL pattern
/// (first match wins). A request that matches no route **throws**, so an
/// unexpected call fails the test loudly instead of silently hitting the
/// network. Extends [http.BaseClient], so every `Client` convenience
/// method (`get`, `post`, …) routes through the recording `send`:
///
/// ```dart
/// final transport = FakeHttpTransport()
///   ..routeJson(
///     url: 'https://oauth2.googleapis.com/token',
///     json: (r) => {'access_token': 'test-token', 'expires_in': 3600},
///   );
/// // later:
/// expect(transport.requests.map((r) => r.url.toString()), [
///   'https://oauth2.googleapis.com/token',
///   'https://androidpublisher.googleapis.com/...',
/// ]);
/// transport.assertNoRequests(); // dry-run zero-HTTP law
/// ```
class FakeHttpTransport extends http.BaseClient {
  final _routes = <({Pattern url, FakeRouteHandler handle})>[];

  /// Every request this transport has seen, in order.
  final List<RecordedRequest> requests = [];

  /// Routes requests whose URL contains/matches [url] (a [Pattern] over the
  /// full URL string) to [handle]. First matching route wins.
  void route({required Pattern url, required FakeRouteHandler handle}) =>
      _routes.add((url: url, handle: handle));

  /// Route sugar: reply with a JSON body built per request.
  void routeJson({
    required Pattern url,
    required Object? Function(RecordedRequest request) json,
    int status = 200,
  }) =>
      route(
        url: url,
        handle: (final r) => ScriptedResponse(status: status, json: json(r)),
      );

  /// Route sugar: reply with a fixed JSON body.
  void routeJsonAlways({required Pattern url, required Object? json}) =>
      routeJson(url: url, json: (final _) => json);

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) async {
    final bodyBytes = await _drain(request);
    final recorded = RecordedRequest(
      method: request.method,
      url: request.url,
      headers: Map.unmodifiable(request.headers),
      body: bodyBytes,
    );
    requests.add(recorded);
    final urlText = request.url.toString();
    for (final route_ in _routes) {
      if (!_matches(route_.url, urlText)) continue;
      final response = route_.handle(recorded);
      return http.StreamedResponse(
        Stream.value(response.payload),
        response.status,
        headers: response.headers,
        request: request,
      );
    }
    throw StateError(
      'FakeHttpTransport: unexpected HTTP request (tests must be fully '
      'scripted and offline — no real network, ever): $recorded',
    );
  }

  /// Strings match as substrings (a URL fragment such as the host+path is
  /// enough); other patterns match via [Pattern.allMatches].
  static bool _matches(final Pattern pattern, final String urlText) {
    final p = pattern;
    if (p is String) return urlText.contains(p);
    return p.allMatches(urlText).isNotEmpty;
  }

  static Future<List<int>> _drain(final http.BaseRequest request) async {
    if (request is http.Request) return request.bodyBytes;
    // Auth wrappers (e.g. googleapis_auth's AuthenticatedClient) re-wrap
    // requests with streamed bodies — drain the finalized stream.
    final builder = BytesBuilder();
    await request.finalize().forEach(builder.add);
    return builder.takeBytes();
  }

  /// Number of requests seen (0 = the zero-HTTP law holds).
  int get requestCount => requests.length;

  /// Asserts no HTTP was issued — the dry-run law, as an assertion.
  void assertNoRequests() {
    if (requests.isNotEmpty) {
      throw StateError(
        'FakeHttpTransport: expected zero HTTP requests, saw '
        '${requests.length}: ${requests.join(', ')}',
      );
    }
  }

  @override
  void close() {}
}
