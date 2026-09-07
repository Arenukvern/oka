import 'package:meta/meta.dart';

/// A typed **path reference** to a build-host credential file (ADR-0014).
///
/// The three-tier secrets model (ADR-0014) keeps store-publishing
/// credentials out of binaries, logs, git, and [PipelineState] by never
/// handling values at all: typed config holds a *path* (or an env var
/// naming a path, or the well-known location), and the file is consumed on
/// the build host by oka steps. A [CredentialRef] is that path reference as
/// a value:
///
/// ```dart
/// const serviceAccount = CredentialRef(
///   target: 'play',
///   kind: 'service-account-json',
///   explicitPath: 'credentials/play-service-account.json', // typed config
/// );
/// ```
///
/// Fields are non-secret by construction — [explicitPath] is the only
/// locational data. [toString] is the **redacting** form (safe for logs,
/// events, and [PipelineState] dumps): it names the target and kind but
/// never the path. Doctor and diagnostics use [describe], which may show
/// the path but can never show a value (a ref holds none).
@immutable
class CredentialRef {
  const CredentialRef({
    required this.target,
    required this.kind,
    this.explicitPath,
    this.envVar,
    this.wellKnownFileName,
  });

  /// Publishing target the credential belongs to, e.g. `'play'`. Lowercase
  /// identifier; also the directory under `~/.oka/credentials/`.
  final String target;

  /// What the credential is, e.g. `'service-account-json'`, `'keystore'`.
  final String kind;

  /// Explicit path from typed config (highest-precedence policy source).
  /// Optional; when set and missing, resolution fails without falling
  /// through (same hard boundary as tool config, ADR-0013).
  final String? explicitPath;

  /// Env var naming the credential *path* (never a value). Defaults to
  /// `OKA_<TARGET>_<KIND>`, e.g. `OKA_PLAY_SERVICE_ACCOUNT_JSON`.
  final String? envVar;

  /// File name at the well-known location
  /// `~/.oka/credentials/<target>/`. Defaults to [kind] lowercased.
  final String? wellKnownFileName;

  /// Env var this ref resolves through: [envVar] or the derived
  /// `OKA_<TARGET>_<KIND>`.
  String get envVarName =>
      envVar ?? 'OKA_${_envSafe(target)}_${_envSafe(kind)}';

  /// File name used at the well-known location.
  String get wellKnownFileNameOrDefault =>
      wellKnownFileName ?? _fileSafe(kind);

  /// Well-known location (home-relative form, `~`-prefixed) — the last
  /// policy candidate, e.g. `~/.oka/credentials/play/service-account-json`.
  String get wellKnownPath =>
      '~/.oka/credentials/$target/$wellKnownFileNameOrDefault';

  /// Redacting form: safe for logs, events, and [PipelineState] dumps.
  /// Never contains [explicitPath] or any resolved path.
  @override
  String toString() => 'CredentialRef($target/$kind → [redacted])';

  /// Diagnostic form for doctor and step diagnostics: the *path* may
  /// appear; a value never can (a ref holds none by construction).
  String describe([final String? resolvedPath]) => resolvedPath == null
      ? 'CredentialRef($target/$kind)'
      : 'CredentialRef($target/$kind at $resolvedPath)';

  @override
  bool operator ==(final Object other) =>
      other is CredentialRef &&
      other.target == target &&
      other.kind == kind &&
      other.explicitPath == explicitPath &&
      other.envVarName == envVarName &&
      other.wellKnownFileNameOrDefault == wellKnownFileNameOrDefault;

  @override
  int get hashCode => Object.hash(
        target,
        kind,
        explicitPath,
        envVarName,
        wellKnownFileNameOrDefault,
      );
}

/// Upper-snake-safe env fragment: `play-store` → `PLAY_STORE`.
String _envSafe(final String s) =>
    s.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '_');

/// File-name-safe fragment: `service_account.json` → `service-account-json`.
String _fileSafe(final String s) =>
    s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
