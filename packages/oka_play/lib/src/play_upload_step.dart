import 'dart:io';

import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:oka_core/oka_core.dart';

import 'play_credentials.dart';
import 'play_publisher_client.dart';
import 'play_target.dart';

/// Creates the OAuth-authenticated [http.Client] from the service-account
/// JSON map and a base client.
///
/// Production: googleapis_auth's `clientViaServiceAccount` — the JWT is
/// signed locally (RS256) and exchanged at the token endpoint over
/// [baseClient] (injectable, so tests run fully offline).
typedef PlayAuthClientFactory = Future<http.Client> Function(
  Map<String, dynamic> serviceAccountJson,
  http.Client baseClient,
);

Future<http.Client> _googleAuthClientFactory(
  final Map<String, dynamic> serviceAccountJson,
  final http.Client baseClient,
) =>
    gauth.clientViaServiceAccount(
      gauth.ServiceAccountCredentials.fromJson(serviceAccountJson),
      [androidPublisherScope],
      baseClient: baseClient, // googleapis_auth never closes the base client
    );

/// The real upload tail: Play Publisher API Edits flow over the composed
/// AAB (ADR-0014 publish contract).
///
/// Requires `Artifact<String>('aab-path')`; provides
/// `Artifact<int>('play-version-code')`. Credential resolution goes through
/// [CredentialResolver] (ordered policy: typed-config path →
/// `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var → well-known location); the
/// service-account file is read **by path** and its contents never enter
/// [PipelineState], logs, or events. No standard-input reads, no
/// interactivity.
///
/// Test seams: [credentialResolver] (injected env), [httpClient]
/// (transport), and [authClientFactory] (token exchange) — the conformance
/// tests run the full flow against a scripted fake transport, offline.
class PlayUploadStep extends BuildStep {
  PlayUploadStep(
    this.target, {
    final CredentialResolver? credentialResolver,
    this.httpClient,
    final PlayAuthClientFactory? authClientFactory,
  })  : credentialResolver =
            credentialResolver ?? CredentialResolver.platform(),
        authClientFactory = authClientFactory ?? _googleAuthClientFactory;

  /// The publish target this step uploads for.
  final PlayPublishTarget target;

  /// Injected resolver (tests use an injected environment); default is the
  /// platform resolver.
  final CredentialResolver credentialResolver;

  /// Injected transport (tests use a scripted fake); null → a real
  /// `http.Client` is created per run and closed afterwards.
  final http.Client? httpClient;

  /// Auth client factory (tests may skip the JWT exchange entirely).
  final PlayAuthClientFactory authClientFactory;

  /// The version code assigned by the bundle upload (a number — allowed in
  /// [PipelineState] by the ADR-0014 law 3).
  static const Artifact<int> playVersionCode =
      Artifact<int>('play-version-code');

  /// Step name: `play-upload`.
  @override
  String get name => 'play-upload';

  /// Requires the staged AAB.
  @override
  Set<Artifact<Object>> get requires => {StageAabStep.aab};

  /// Provides the assigned version code.
  @override
  Set<Artifact<Object>> get provides => {playVersionCode};

  /// Resolves the AAB and credentials, then runs the Edits flow via the
  /// injectable transport; fails actionably on missing artifact, missing
  /// AAB file, invalid config, or API errors.
  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final aabPath = state[StageAabStep.aab.id] as String?;
    if (aabPath == null || aabPath.isEmpty) {
      return StepResult.failure(
        'artifact "${StageAabStep.aab.id}" is missing — the Play upload '
        'consumes the AAB produced by the Android build '
        '(build with `buildAab: true`, or compose this target after the '
        'Android pipeline)',
      );
    }
    if (!File(aabPath).existsSync()) {
      return StepResult.failure(
        'AAB not found at $aabPath — build the AAB first '
        '(`oka build` with buildAab, or point aab-path at the bundle to '
        'upload)',
      );
    }
    final configIssues = target.validateConfig();
    if (configIssues.isNotEmpty) {
      return StepResult.failure(
        'PlayPublishTarget config is invalid:\n'
        '${configIssues.map((final i) => '  - $i').join('\n')}',
      );
    }

    // Credential resolution — paths only, values never.
    final CredentialResolution resolution;
    try {
      resolution = credentialResolver.require(target.serviceAccountRef);
    } on CredentialResolutionException catch (e) {
      return StepResult.failure(e.toString());
    }
    final credentialPath = resolution.path!;

    // Read + shape-check the service-account JSON. Values stay in memory
    // only; failures name missing fields, never contents.
    final Map<String, dynamic> serviceAccountJson;
    try {
      serviceAccountJson =
          parseServiceAccountJson(File(credentialPath).readAsStringSync());
    } on ServiceAccountFormatException catch (e) {
      return StepResult.failure(
        '$e (file: ${target.serviceAccountRef.describe(credentialPath)})',
      );
    }

    final ownedClient = httpClient ?? http.Client();
    try {
      final authClient = await authClientFactory(
        serviceAccountJson,
        ownedClient,
      );
      try {
        final api = PlayPublisherClient(
          client: authClient,
          packageName: target.packageName,
        );
        final result = await api.publishAab(
          aabPath: aabPath,
          track: target.track,
          userFraction: target.userFraction,
          releaseName: target.releaseName.isEmpty ? null : target.releaseName,
        );
        // State law (ADR-0014): refs/booleans/numbers/paths only — no
        // credential material, no response payloads.
        state[playVersionCode.id] = result.versionCode;
        return StepResult.success({
          'play-edit-id': result.editId,
          'play-version-code': result.versionCode,
          'play-track': target.track,
          'aab-path': aabPath,
        });
      } finally {
        // googleapis_auth guarantees it does not close the baseClient it
        // was handed; closing the auth client releases only its own
        // resources. The base client is closed below when we created it.
        authClient.close();
      }
    } on PlayApiException catch (e) {
      return StepResult.failure(e.toString());
    } on http.ClientException catch (e) {
      return StepResult.failure(
        'Play upload failed on the network path (no network in tests; '
        'check connectivity/proxy): $e',
      );
    } finally {
      if (httpClient == null) ownedClient.close();
    }
  }
}
