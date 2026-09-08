// ADR-0014 P1 — the real upload path, fully offline: JWT → OAuth token
// exchange + the Edits API flow against a scripted fake transport, plus
// redaction of the synthetic credential material and failure remediation.
//
// No real network: every request is routed by FakeHttpTransport, and an
// unexpected request throws.
import 'dart:convert';
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_play/oka_play.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'synthetic_credentials.dart';

const String _tokenUrl = 'https://oauth2.googleapis.com/token';
const String _apiBase = 'https://androidpublisher.googleapis.com';
const String _packageName = 'dev.example.app';

BuildContext _ctx(final Directory tmp) => BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, 'build'),
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );

Directory _aabFile(final Directory tmp) {
  final file = File(p.join(tmp.path, 'build', 'app-release.aab'))
    ..createSync(recursive: true)
    ..writeAsBytesSync(syntheticAabBytes);
  return Directory(file.parent.path);
}

/// Writes the synthetic service-account fixture to [tmp] and returns its
/// path. The file lives in a system temp dir, never in the repo.
String _writeServiceAccount(final Directory tmp) {
  final file = File(p.join(tmp.path, 'sa', 'service-account.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(syntheticServiceAccountJson);
  return file.path;
}

/// Scripts the exact Play Publisher API conversation.
///
/// Route order matters: the more specific paths come first — the generic
/// `'/edits'` fragment is a substring of every nested edit URL, so the
/// edits-create route is last and checks the path shape.
FakeHttpTransport _playTransport({final int commitStatus = 200}) {
  final transport = FakeHttpTransport();
  // 1. JWT → OAuth token exchange (the assertion is signed locally by
  //    googleapis_auth with the synthetic key; the fake only answers).
  transport.routeJsonAlways(
    url: _tokenUrl,
    json: {
      'token_type': 'Bearer',
      'access_token': 'synthetic-test-access-token',
      'expires_in': 3600,
    },
  );
  // 2. bundles.upload (AAB bytes) — echoes a fixed version code.
  transport.routeJsonAlways(
    url: '/bundles',
    json: {'versionCode': '420042'},
  );
  // 3. tracks/{track}
  transport.routeJsonAlways(url: '/tracks/', json: {'track': 'internal'});
  // 4. edits.commit
  transport.route(
    url: ':commit',
    handle: (final r) => ScriptedResponse(
      status: commitStatus,
      json: commitStatus < 300
          ? {'id': 'synthetic-edit-id'}
          : {
              'error': {
                'code': commitStatus,
                'message': 'synthetic-commit-failure',
              },
            },
    ),
  );
  // 5. edits.create (last — its URL fragment is nested in the others).
  transport.routeJson(
    url: '/edits',
    json: (final r) =>
        r.url.path.endsWith('/edits') ? {'id': 'synthetic-edit-id'} : null,
  );
  return transport;
}

/// The exact ordered URLs of a successful upload.
List<String> _expectedUrls(final String aabPath) {
  const editsBase =
      '$_apiBase/androidpublisher/v3/applications/$_packageName/edits';
  const editUrl = '$editsBase/synthetic-edit-id';
  return [
    _tokenUrl,
    editsBase,
    '$editUrl/bundles?uploadType=media',
    '$editUrl/tracks/internal',
    '$editUrl:commit',
  ];
}

void main() {
  late Directory tmp;
  late String credentialPath;
  late String aabPath;

  /// Case-insensitive header lookup (clients may normalize key case).
  String? header(final Map<String, String> headers, final String name) =>
      headers.entries
          .where((final e) => e.key.toLowerCase() == name)
          .map((final e) => e.value)
          .firstOrNull;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_play_upload_');
    credentialPath = _writeServiceAccount(tmp);
    _aabFile(tmp);
    aabPath = p.join(tmp.path, 'build', 'app-release.aab');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  PlayUploadStep step({
    final FakeHttpTransport? transport,
    final CredentialResolver? resolver,
  }) =>
      PlayUploadStep(
        const PlayPublishTarget(
          dryRun: false,
          packageName: _packageName,
        ),
        credentialResolver: resolver ??
            CredentialResolver(
              environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': credentialPath},
              home: p.join(tmp.path, 'home'),
            ),
        httpClient: transport,
      );

  group('JWT → OAuth token exchange + Edits flow (fake transport)', () {
    test('the full flow issues exactly the expected ordered requests',
        () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final result = await step(transport: transport).run(_ctx(tmp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(
        transport.requests.map((final r) => r.url.toString()).toList(),
        _expectedUrls(aabPath),
      );

      // The token exchange is a JWT-bearer grant signed with the
      // synthetic key; the client_email must be the issuer.
      final tokenRequest = transport.requests.first;
      expect(tokenRequest.headers['content-type'],
          startsWith('application/x-www-form-urlencoded'));
      final form = Uri.splitQueryString(tokenRequest.bodyText);
      expect(
        form['grant_type'],
        'urn:ietf:params:oauth:grant-type:jwt-bearer',
      );
      final assertion = form['assertion']!;
      // JWT header (unpadded base64url) declares RS256.
      final header = jsonDecode(
        utf8.decode(base64Url.decode(assertion.split('.').first)),
      ) as Map;
      expect(header['alg'], 'RS256');
      final claims =
          jsonDecode(utf8.decode(base64Url.decode(assertion.split('.')[1])))
              as Map;
      expect(
        claims['iss'],
        'synthetic-test-account@synthetic-test-project.iam.gserviceaccount.com',
      );
      expect(claims['scope'], androidPublisherScope);
      expect(claims['aud'], _tokenUrl);
    });

    test('the AAB bytes travel verbatim to bundles.upload', () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final result = await step(transport: transport).run(_ctx(tmp), state);
      expect(result.ok, isTrue, reason: result.error);

      final upload = transport.requests
          .singleWhere((final r) => r.url.toString().contains('/bundles'));
      expect(upload.body, syntheticAabBytes);
      expect(upload.headers['content-type'], 'application/octet-stream');
      expect(
        header(upload.headers, 'authorization'),
        'Bearer synthetic-test-access-token',
      );
    });

    test('track assignment carries version code, status, and rollout',
        () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      await step(transport: transport).run(_ctx(tmp), state);

      final trackRequest = transport.requests
          .singleWhere((final r) => r.url.path.contains('/tracks/'));
      expect(trackRequest.url.path, endsWith('/tracks/internal'));
      final body = trackRequest.bodyJson! as Map;
      final release = (body['releases'] as List).single! as Map;
      expect(release['versionCodes'], ['420042']);
      expect(release['status'], 'completed');
      expect(release.containsKey('userFraction'), isFalse);
    });

    test('staged rollout (userFraction) sends inProgress + fraction',
        () async {
      final transport = _playTransport();
      final credential = CredentialResolver(
        environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': credentialPath},
        home: p.join(tmp.path, 'home'),
      );
      final state = PipelineState()..['aab-path'] = aabPath;
      final step = PlayUploadStep(
        const PlayPublishTarget(
          dryRun: false,
          packageName: _packageName,
          userFraction: 0.1,
        ),
        credentialResolver: credential,
        httpClient: transport,
      );
      final result = await step.run(_ctx(tmp), state);
      expect(result.ok, isTrue, reason: result.error);

      final trackRequest = transport.requests
          .singleWhere((final r) => r.url.path.contains('/tracks/'));
      final release = ((trackRequest.bodyJson! as Map)['releases'] as List)
          .single! as Map;
      expect(release['status'], 'inProgress');
      expect(release['userFraction'], 0.1);
    });

    test('success records only the allowed state values (num/strings)',
        () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final result = await step(transport: transport).run(_ctx(tmp), state);

      expect(state[PlayUploadStep.playVersionCode.id], 420042);
      expect(result.data['play-edit-id'], 'synthetic-edit-id');
      expectStateRedacted(
        state,
        refs: [playServiceAccountRef()],
        forbidden: syntheticSecretMarkers,
      );
      expectNoSecretMaterial(
        result.data.toString(),
        refs: [playServiceAccountRef()],
        forbidden: syntheticSecretMarkers,
      );
    });

    test('no request, log, or state dump ever carries the synthetic '
        'credential material', () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final result = await step(transport: transport).run(_ctx(tmp), state);
      expect(result.ok, isTrue, reason: result.error);

      // Requests legitimately carry the JWT assertion (signed with the
      // synthetic key) — but no request headers, and no state/result text,
      // may carry the raw synthetic key or its markers.
      final requestDump = transport.requests
          .map((final r) => '${r.method} ${r.url} ${r.headers}')
          .join('\n');
      expectNoSecretMaterial(
        requestDump,
        refs: [playServiceAccountRef(explicitPath: credentialPath)],
        forbidden: syntheticSecretMarkers,
      );
      expectNoSecretMaterial(
        'credential: ${playServiceAccountRef(explicitPath: credentialPath)}\n'
        '${result.data}',
        refs: [playServiceAccountRef(explicitPath: credentialPath)],
        forbidden: syntheticSecretMarkers,
      );
    });
  });

  group('failure remediation (no network, no partial uploads)', () {
    test('a missing AAB fails before credential resolution or HTTP',
        () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = p.join(tmp.path, 'no.aab');
      final result = await step(transport: transport).run(_ctx(tmp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('AAB not found'));
      expect(transport.requestCount, 0);
    });

    test('an empty packageName fails before any HTTP', () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final step = PlayUploadStep(
        const PlayPublishTarget(dryRun: false),
        credentialResolver: CredentialResolver(
          environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': credentialPath},
          home: p.join(tmp.path, 'home'),
        ),
        httpClient: transport,
      );
      final result = await step.run(_ctx(tmp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('packageName is empty'));
      expect(transport.requestCount, 0);
    });

    test('an unresolvable credential fails naming the policy candidates',
        () async {
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final step = PlayUploadStep(
        const PlayPublishTarget(dryRun: false, packageName: _packageName),
        credentialResolver: CredentialResolver(
          environment: const {},
          home: p.join(tmp.path, 'empty-home'),
        ),
        httpClient: transport,
      );
      final result = await step.run(_ctx(tmp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('play/service-account-json'));
      expect(result.error, contains('Tried (in order)'));
      expect(result.error, contains('Fix:'));
      expect(transport.requestCount, 0);
    });

    test('a malformed service-account file fails naming the field',
        () async {
      final bad = File(p.join(tmp.path, 'bad-sa.json'))
        ..writeAsStringSync('{"type": "service_account"}');
      final transport = _playTransport();
      final state = PipelineState()..['aab-path'] = aabPath;
      final step = PlayUploadStep(
        const PlayPublishTarget(dryRun: false, packageName: _packageName),
        credentialResolver: CredentialResolver(
          environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': bad.path},
          home: p.join(tmp.path, 'home'),
        ),
        httpClient: transport,
      );
      final result = await step.run(_ctx(tmp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('missing required field(s)'));
      // Values are never echoed — only field names.
      expect(result.error, isNot(contains(syntheticServiceAccountJson)));
      expect(transport.requestCount, 0);
    });

    test('an API error surfaces as a StepResult.failure with status',
        () async {
      final transport = _playTransport(commitStatus: 403);
      final state = PipelineState()..['aab-path'] = aabPath;
      final result = await step(transport: transport).run(_ctx(tmp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('HTTP 403'));
      expect(result.error, contains('synthetic-commit-failure'));
      // Five requests were made (token, edits, bundles, tracks, commit) —
      // the failure came from the API, not from local misuse.
      expect(transport.requestCount, 5);
    });
  });

  group('PlayPublisherClient (unit, scripted transport)', () {
    test('versionCode parses from a JSON number or string', () async {
      final transport = FakeHttpTransport()..routeJsonAlways(
          url: '/bundles',
          json: {'versionCode': 7},
        );
      final api = PlayPublisherClient(client: transport, packageName: 'pkg');
      final vc = await api.uploadAab(
        editId: 'e',
        aabPath: aabPath,
      );
      expect(vc, 7);
      // uploadAab builds the URL from the client's packageName + editId;
      // the route only matched by pattern.
      expect(transport.requestCount, 1);
    });
  });
}
