import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:oka_core/oka_core.dart';

import 'agc_api.dart';
import 'agc_credentials.dart';
import 'huawei_release_config.dart';

/// Stages the publish artifact for the Huawei upload tail: resolves the
/// AAB path (an upstream step may provide `aab-path` — otherwise the
/// default build-dir location) and provides it under the target's
/// [artifactId].
///
/// Pure with respect to the filesystem: it never checks existence — the
/// dry-run law requires the stage to run with an empty state and no
/// credentials, producing a plan for an artifact that may not exist yet.
/// The real upload step ([AgcPublishStep]) enforces existence before any
/// HTTP call and fails naming the path.
class HuaweiStageAabStep extends BuildStep {
  HuaweiStageAabStep();

  /// The staged AAB path (consumed by the plan step and the upload tail).
  static const aabPath = Artifact<String>('aab-path');

  @override
  String get name => 'huawei-stage-aab';

  @override
  Set<Artifact<Object>> get provides => {aabPath};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final existing = state[aabPath.id];
    if (existing is String && existing.isNotEmpty) {
      // Composed after a platform build that already staged the AAB.
      return StepResult.success({'aab-path': existing});
    }
    final staged = '${ctx.buildDir}${ctx.buildDir.endsWith('/') ? '' : '/'}'
        'app-release.aab';
    state[aabPath.id] = staged;
    return StepResult.success({'aab-path': staged});
  }
}

/// The real upload tail: AGC token fetch → upload-url → artifact upload →
/// submit (ADR-0014 P2).
///
/// Conformance notes:
///
/// * **No interactive input, ever** — failures are [StepResult.failure] values naming
///   the fix.
/// * **No secret values in state** — credentials and the token live only
///   in this step's local scope; state receives the artifact path, the
///   submit receipt fields, and nothing else.
/// * **Credential material by path** — the credential file is resolved
///   through the P0 [CredentialResolver] policy (`huawei/
///   agconnect-credentials`); the message on failure lists every candidate
///   tried and the fix.
class AgcPublishStep extends BuildStep {
  AgcPublishStep({
    required this.release,
    required this.credentialRef,
    this.credentialResolver,
    this.endpoints = const AgcEndpoints(),
    this.httpFactory,
  }) : _resolver = credentialResolver;

  /// The release metadata (non-secret) — track, notes, phase.
  final HuaweiReleaseConfig release;

  /// The credential path reference (`huawei/agconnect-credentials`).
  final CredentialRef credentialRef;

  /// Injected credential resolver (tests); null → platform default.
  final CredentialResolver? credentialResolver;
  final CredentialResolver? _resolver;

  /// AGC endpoints (tests point these at the fake transport).
  final AgcEndpoints endpoints;

  /// HTTP transport factory (tests inject a fake; production uses a real
  /// [http.Client]).
  final http.Client Function()? httpFactory;

  @override
  String get name => 'agc-publish';

  @override
  Set<Artifact<Object>> get requires => {HuaweiStageAabStep.aabPath};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final artifactPath = state[HuaweiStageAabStep.aabPath.id] as String?;
    if (artifactPath == null || artifactPath.isEmpty) {
      return StepResult.failure(
        'no AAB staged — compose this step after a step providing '
        '"${HuaweiStageAabStep.aabPath.id}" (the Huawei target does this '
        'automatically)',
      );
    }
    final artifact = File(artifactPath);
    if (!artifact.existsSync()) {
      return StepResult.failure(
        'the publish artifact does not exist: $artifactPath — build the '
        'AAB first (oka build aab --release)',
      );
    }

    // Credential by path — the file is read here and its contents never
    // leave this scope (no state, no logs, no events).
    final resolver = _resolver ?? CredentialResolver();
    final CredentialResolution resolution;
    try {
      resolution = resolver.require(credentialRef);
    } on CredentialResolutionException catch (e) {
      return StepResult.failure(e.toString());
    }
    final String credentialJson;
    try {
      credentialJson = await File(resolution.path!).readAsString();
    } on IOException catch (e) {
      return StepResult.failure(
        'cannot read the agconnect credentials file at '
        '${resolution.path}: $e — fix the file permissions or the path',
      );
    }
    final AgcCredentials credentials;
    try {
      credentials = AgcCredentials.parse(credentialJson);
    } on FormatException catch (e) {
      return StepResult.failure(e.message);
    }

    // Release-note contents are read from their files at publish time and
    // placed straight into the submit payload — never into state.
    final noteContents =
        <({String language, String content})>[];
    for (final note in release.releaseNotes) {
      final noteFile = File(note.file);
      if (!noteFile.existsSync()) {
        return StepResult.failure(
          'release note file for "${note.language}" not found: '
          '${note.file} — create it or drop the language from the typed '
          'config',
        );
      }
      noteContents.add(
        (language: note.language, content: await noteFile.readAsString()),
      );
    }

    final client = AgcClient(
      client: httpFactory != null ? httpFactory!() : http.Client(),
      endpoints: endpoints,
    );
    try {
      final token = await client.fetchToken(credentials);
      final session = await client.requestUploadSession(
        token: token,
        appId: release.appId,
        suffix: 'aab',
      );
      await client.uploadArtifact(
        session: session,
        bytes: await artifact.readAsBytes(),
      );
      final receipt = await client.submit(
        token: token,
        appId: release.appId,
        payload: release.submitPayload(releaseNoteContents: noteContents),
      );
      // Non-secret receipt fields only.
      state['agc-submitted'] = true;
      if (receipt.version.isNotEmpty) state['agc-version'] = receipt.version;
      return StepResult.success({
        'agc-submit-id': receipt.submitId,
        'agc-version': receipt.version,
      });
    } on AgcApiException catch (e) {
      return StepResult.failure(e.toString());
    }
  }
}

/// Renders the submit payload as the exact JSON the real run would send
/// (without release-note contents — those are files, resolved at publish
/// time). Used by diagnostics and tests; never contains secrets.
String describeSubmitPayload(final HuaweiReleaseConfig release) =>
    const JsonEncoder.withIndent('  ').convert(
      release.submitPayload(
        releaseNoteContents: const <({String language, String content})>[],
      ),
    );
