// ADR-0014 P2 — the AppGallery Connect publish flow (token fetch →
// upload-url → artifact upload → submit) against a scripted fake HTTP
// transport: fully offline, fully ordered, with redaction assertions.
//
// No real network, no real credentials: every secret in this file is a
// synthetic fixture value whose *absence* from state, logs, results, and
// errors is itself asserted.
import 'dart:convert';
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_huawei/oka_huawei.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Synthetic credential material — fixture values only, never real.
const _syntheticClientId = 'synthetic-agc-client-id';
const _syntheticClientSecret = 'synthetic-agc-client-secret';
const _syntheticToken = 'synthetic-agc-access-token';
const _syntheticAabBytes = [0x50, 0x4b, 0x03, 0x04, 0xde, 0xad, 0xbe, 0xef];

final _forbiddenMaterial = [
  _syntheticClientSecret,
  _syntheticToken,
];

void main() {
  late Directory tmp;
  late String credentialsPath;
  late String aabPath;

  FakeHttpTransport makeTransport() => FakeHttpTransport()
    ..routeJson(
      url: 'api/oauth2/v1/token',
      json: (final _) => {'access_token': _syntheticToken, 'expires_in': 3600},
    )
    ..routeJson(
      url: 'api/publish/v2/upload-url',
      json: (final _) => {'uploadUrl': 'https://upload.fake/agc/1', 'session': 'session-1'},
    )
    ..route(
      url: 'upload.fake/agc/1',
      handle: (final _) => const ScriptedResponse(
        json: {'result': 0},
        headers: {'content-type': 'application/octet-stream'},
      ),
    )
    ..routeJson(
      url: 'api/publish/v2/app-submit',
      json: (final _) => {
        'ret': {'code': 0, 'msg': 'Success'},
        'version': '1.2.3',
        'submitId': 'submit-1',
      },
    );

  AgcPublishStep makeStep({
    required FakeHttpTransport transport,
    String? noteFile,
    HuaweiReleaseConfig? release,
  }) =>
      AgcPublishStep(
        release: release ??
            HuaweiReleaseConfig(
              appId: '110012345',
              releaseNotes: [
                if (noteFile != null)
                  AgcReleaseNote(
                    language: 'en',
                    file: p.join(tmp.path, 'synthetic-whatsnew-en.txt'),
                  ),
              ],
            ),
        credentialRef: CredentialRef(
          target: 'huawei',
          kind: 'agconnect-credentials',
          explicitPath: credentialsPath,
        ),
        credentialResolver: CredentialResolver(home: tmp.path),
        endpoints: const AgcEndpoints(baseUrl: 'https://connect-api.fake'),
        httpFactory: () => transport,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_huawei_agc_test_');
    credentialsPath = p.join(tmp.path, 'agconnect-credentials.json');
    File(credentialsPath).writeAsStringSync(
      jsonEncode({
        'client_id': _syntheticClientId,
        'client_secret': _syntheticClientSecret,
      }),
    );
    aabPath = p.join(tmp.path, 'app-release.aab');
    File(aabPath).writeAsBytesSync(_syntheticAabBytes);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  PipelineState makeState() => PipelineState()
    ..[HuaweiStageAabStep.aabPath.id] = aabPath;

  test('the full flow: token → upload-url → PUT artifact → submit, in order',
      () async {
    final transport = makeTransport();
    final step = makeStep(transport: transport, noteFile: 'ok');
    File(p.join(tmp.path, 'synthetic-whatsnew-en.txt'))
        .writeAsStringSync('Synthetic release notes');
    final ctx = BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, 'build'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );
    final result = await step.run(ctx, makeState());

    expect(result.ok, isTrue, reason: result.error);
    expect(transport.requestCount, 4);

    // 1. Token: client-credentials grant carries the API-client secret —
    //    on the wire only, never in state/results (asserted below).
    final token = transport.requests[0];
    expect(token.method, 'POST');
    expect(token.url.toString(), contains('api/oauth2/v1/token'));
    expect(token.bodyText, contains('grant_type=client_credentials'));
    expect(token.bodyText, contains(_syntheticClientId));
    expect(token.bodyText, contains(_syntheticClientSecret));

    // 2. Upload URL: bearer-authenticated, aab suffix, appId.
    final uploadUrl = transport.requests[1];
    expect(uploadUrl.url.toString(), contains('api/publish/v2/upload-url'));
    expect(uploadUrl.url.queryParameters['appId'], '110012345');
    expect(uploadUrl.url.queryParameters['suffix'], 'aab');
    expect(uploadUrl.headers['authorization'], 'Bearer $_syntheticToken');
    expect(uploadUrl.bodyText, isNot(contains(_syntheticClientSecret)));

    // 3. Upload: the artifact bytes, byte-exact.
    final upload = transport.requests[2];
    expect(upload.method, 'PUT');
    expect(upload.url.toString(), contains('upload.fake/agc/1'));
    expect(upload.body, _syntheticAabBytes);

    // 4. Submit: appId + typed release metadata (track, notes, phase).
    final submit = transport.requests[3];
    expect(submit.url.toString(), contains('api/publish/v2/app-submit'));
    final payload = submit.bodyJson! as Map<dynamic, dynamic>;
    expect(payload['appId'], '110012345');
    final release = payload['release'] as Map<dynamic, dynamic>;
    expect(release['phasePercent'], 100);
    expect(
      (release['releaseNotes'] as List).single,
      containsPair('language', 'en'),
    );
  });

  test('state and result data hold no secret material', () async {
    final transport = makeTransport();
    final step = makeStep(transport: transport);
    final ctx = BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, 'build'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );
    final state = makeState();
    final result = await step.run(ctx, state);

    expect(result.ok, isTrue, reason: result.error);
    // Law 3 over a *real-run* state — expectStateRedacted covers both the
    // value-type law and forbidden-material scanning.
    expectStateRedacted(
      state,
      forbidden: _forbiddenMaterial,
    );
    expectNoSecretMaterial(
      result.data.entries.map((final e) => '${e.key}: ${e.value}').join('\n'),
      forbidden: _forbiddenMaterial,
      context: 'step result data',
    );
    expect(state.snapshot['agc-submitted'], isTrue);
    expect(state.snapshot['agc-version'], '1.2.3');
  });

  test('credential values redact on dump (AgcCredentials, AgcToken)',
      () async {
    final transport = makeTransport();
    final step = makeStep(transport: transport);
    final ctx = BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, 'build'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );
    await step.run(ctx, makeState());

    final credentials = AgcCredentials.parse(
      File(credentialsPath).readAsStringSync(),
    );
    const token = AgcToken(value: _syntheticToken, expiresInSeconds: 3600);
    final dump = [credentials.toString(), token.toString()].join('\n');

    // The redacting forms never carry the secret values.
    expectNoSecretMaterial(
      dump,
      forbidden: _forbiddenMaterial,
      context: 'credential/token dump',
    );
    expect(
      credentials.toString(),
      'AgcCredentials(client_id: [redacted], client_secret: [redacted])',
    );
    expect(token.toString(), contains('[redacted]'));
    // And the checker really bites when material is present.
    expect(
      () => expectNoSecretMaterial(
        'x $credentials $_syntheticClientSecret',
        forbidden: _forbiddenMaterial,
      ),
      throwsA(isA<SecretMaterialException>()),
    );
  });

  group('failures name the fix, never the secret', () {
    BuildContext makeCtx() => BuildContext(
          projectPath: tmp.path,
          buildDir: p.join(tmp.path, 'build'),
          mode: BuildMode.debug,
          config: OkaConfig.empty,
        );

    test('missing artifact fails before any HTTP', () async {
      final transport = makeTransport();
      final step = makeStep(transport: transport);
      final state = PipelineState()
        ..[HuaweiStageAabStep.aabPath.id] = p.join(tmp.path, 'nope.aab');
      final result = await step.run(makeCtx(), state);

      expect(result.ok, isFalse);
      expect(result.error, contains('does not exist'));
      expect(result.error, contains('nope.aab'));
      expect(result.error, contains('oka build aab'));
      transport.assertNoRequests();
    });

    test('missing credential file lists the tried candidates and the fix',
        () async {
      final transport = makeTransport();
      final step = AgcPublishStep(
        release: const HuaweiReleaseConfig(appId: '110012345'),
        credentialRef: CredentialRef(
          target: 'huawei',
          kind: 'agconnect-credentials',
          explicitPath: p.join(tmp.path, 'missing-credentials.json'),
        ),
        credentialResolver: CredentialResolver(home: tmp.path),
        httpFactory: () => transport,
      );
      final result = await step.run(makeCtx(), makeState());

      expect(result.ok, isFalse);
      expect(result.error, contains('not found'));
      expect(result.error, contains('Tried (in order)'));
      expect(result.error, contains('OKA_HUAWEI_AGCONNECT_CREDENTIALS'));
      expect(result.error, contains('~/.oka/credentials/huawei'));
      transport.assertNoRequests();
    });

    test('malformed credentials fail naming the keys, not the values',
        () async {
      File(credentialsPath).writeAsStringSync('{"oops": 1}');
      final transport = makeTransport();
      final result = await makeStep(transport: transport).run(makeCtx(), makeState());

      expect(result.ok, isFalse);
      expect(result.error, contains('client_id'));
      expect(result.error, contains('client_secret'));
      expect(result.error, contains('"oops"'));
      expectNoSecretMaterial(
        result.error ?? '',
        forbidden: _forbiddenMaterial,
        context: 'malformed-credentials error',
      );
      transport.assertNoRequests();
    });

    test('a rejected token maps to a failure naming the status', () async {
      final transport = FakeHttpTransport()
        ..routeJson(
          url: 'api/oauth2/v1/token',
          json: (final _) => {
            'ret': {'code': 5, 'msg': 'invalid client'},
          },
          status: 401,
        );
      final result = await makeStep(transport: transport).run(makeCtx(), makeState());

      expect(result.ok, isFalse);
      expect(result.error, contains('AGC token failed (HTTP 401'));
      expectNoSecretMaterial(
        result.error ?? '',
        forbidden: _forbiddenMaterial,
        context: 'token error',
      );
    });

    test('a failed submit (ret.code != 0) maps to a failure', () async {
      final transport = FakeHttpTransport()
        ..routeJson(
          url: 'api/oauth2/v1/token',
          json: (final _) => {'access_token': _syntheticToken},
        )
        ..routeJson(
          url: 'api/publish/v2/upload-url',
          json: (final _) => {'uploadUrl': 'https://upload.fake/1', 'session': 's'},
        )
        ..route(
          url: 'upload.fake/1',
          handle: (final _) => const ScriptedResponse(json: {'result': 0}),
        )
        ..routeJson(
          url: 'api/publish/v2/app-submit',
          json: (final _) => {
            'ret': {'code': 42, 'msg': 'release rejected'},
          },
        );
      final result = await makeStep(transport: transport).run(makeCtx(), makeState());

      expect(result.ok, isFalse);
      expect(result.error, contains('ret.code 42'));
      expect(result.error, contains('release rejected'));
    });

    test('a missing release-note file fails naming the language', () async {
      final transport = makeTransport();
      final result = await makeStep(
        transport: transport,
        noteFile: 'missing',
      ).run(makeCtx(), makeState());

      expect(result.ok, isFalse);
      expect(result.error, contains('"en"'));
      expect(result.error, contains('synthetic-whatsnew-en.txt'));
      transport.assertNoRequests();
    });
  });

  test('AgcClient and credentials types are redacting and identity-valued',
      () {
    const credentials = AgcCredentials(
      clientId: _syntheticClientId,
      clientSecret: _syntheticClientSecret,
    );
    const token = AgcToken(value: _syntheticToken, expiresInSeconds: 3600);

    expect(credentials.toString(), isNot(contains(_syntheticClientSecret)));
    expect(token.toString(), isNot(contains(_syntheticToken)));
    expect(token.toString(), contains('[redacted]'));
    // Secrets never participate in equality — no accidental leakage via
    // collection keys or == comparisons.
    expect(credentials == credentials, isTrue);
    // Built from a non-const expression: a distinct instance with equal
    //-looking fields must still be unequal (identity equality — secrets
    // never participate in ==).
    final values = [_syntheticClientId, _syntheticClientSecret];
    final same = AgcCredentials(
      clientId: values[0],
      clientSecret: values[1],
    );
    expect(credentials == same, isFalse);
  });
}
