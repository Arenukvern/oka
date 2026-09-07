import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'credential_ref.dart';
import 'repo_hygiene.dart';

/// Where a credential path may come from, in descending order of
/// preference (mirrors [ToolSourceKind] from the T1 tool policy).
enum CredentialSourceKind {
  /// Explicit typed config (the target's credential path field).
  config,

  /// Environment variable naming a *path* (`OKA_<TARGET>_*`).
  env,

  /// Well-known oka location (`~/.oka/credentials/<target>/…`).
  wellKnown,
}

/// One ordered candidate source inside the credential-path policy.
///
/// A plain value, printable by `oka doctor` and listed on resolution
/// failure — same inspectable shape as the T1 tool policy ([ToolSource]).
@immutable
class CredentialSource {
  const CredentialSource(this.kind, this.label);

  final CredentialSourceKind kind;
  final String label;

  /// Printable form, e.g. `env OKA_PLAY_SERVICE_ACCOUNT_JSON`.
  String get qualified => '${kind.name} $label';

  @override
  String toString() => qualified;

  @override
  bool operator ==(final Object other) =>
      other is CredentialSource && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);
}

/// Result of credential-path resolution: the resolved [path] plus every
/// candidate [tried] in order (the remediation law — failures name what
/// was tried and the fix).
@immutable
class CredentialResolution {
  const CredentialResolution({
    required this.ref,
    this.path,
    this.source,
    this.tried = const [],
    this.problem,
  });

  /// The ref that was resolved.
  final CredentialRef ref;

  /// Resolved credential file path, or null when not found.
  final String? path;

  /// The source the path resolved from; null when not found.
  final CredentialSource? source;

  /// Every candidate tried, in policy order.
  final List<CredentialSource> tried;

  /// Human-readable failure reason; null on success.
  final String? problem;

  bool get ok => path != null;
}

/// Thrown when a **required** credential path fails to resolve. Names every
/// candidate tried and the fix — same remediation law as
/// [ToolchainException].
class CredentialResolutionException implements Exception {
  CredentialResolutionException({required this.ref, required this.resolution});

  final CredentialRef ref;
  final CredentialResolution resolution;

  @override
  String toString() {
    final b = StringBuffer(
      'Credential "${ref.target}/${ref.kind}" not found.',
    );
    final tried = resolution.tried;
    if (tried.isNotEmpty) {
      b.write('\nTried (in order):');
      for (var i = 0; i < tried.length; i++) {
        b.write('\n  ${i + 1}. ${tried[i].qualified}');
      }
    }
    b.write('\nFix: ${CredentialResolver.remediationFor(ref)}');
    return b.toString();
  }
}

/// Credential-path resolution policy as data (ADR-0014).
///
/// The ordered policy per [CredentialRef] (mirrors the T1 tool policy
/// shape — inspectable, printable by doctor, unit-testable via injected
/// environment):
///
/// 1. explicit typed-config path ([CredentialRef.explicitPath]) — a missing
///    configured path fails without falling through;
/// 2. `OKA_<TARGET>_*` env var naming a **path** (never a value);
/// 3. well-known `~/.oka/credentials/<target>/<file>`.
///
/// Only paths are resolved here — file *contents* are never read, never
/// stored, never logged. No interactive anything: never reads stdin.
class CredentialResolver {
  CredentialResolver({final Map<String, String>? environment, final String? home})
      : environment = environment ?? Platform.environment,
        home = home ?? _defaultHome(environment ?? Platform.environment);

  factory CredentialResolver.platform() => CredentialResolver();

  /// Injected environment (tests); production is `Platform.environment`.
  final Map<String, String> environment;

  /// Home directory used to expand the well-known location.
  final String home;

  static String _defaultHome(final Map<String, String> env) =>
      env['HOME'] ?? env['USERPROFILE'] ?? '';

  /// The ordered candidate sources for [ref] — the policy as data.
  List<CredentialSource> policyFor(final CredentialRef ref) => [
        if (ref.explicitPath != null)
          CredentialSource(
            CredentialSourceKind.config,
            '${ref.target}/${ref.kind} path in typed config',
          ),
        CredentialSource(CredentialSourceKind.env, ref.envVarName),
        CredentialSource(
          CredentialSourceKind.wellKnown,
          ref.wellKnownPath,
        ),
      ];

  /// Resolves [ref] to a credential file path, or returns the failure with
  /// every candidate tried. Pure w.r.t. secrets: only existence checks.
  CredentialResolution resolve(final CredentialRef ref) {
    final tried = <CredentialSource>[];

    // 1. Explicit typed-config path — hard boundary, no silent fall-through.
    final explicit = ref.explicitPath;
    if (explicit != null) {
      final src = CredentialSource(
        CredentialSourceKind.config,
        '${ref.target}/${ref.kind} path in typed config',
      );
      tried.add(src);
      if (File(explicit).existsSync()) {
        return CredentialResolution(
          ref: ref,
          path: p.normalize(explicit),
          source: src,
          tried: tried,
        );
      }
      return CredentialResolution(
        ref: ref,
        tried: tried,
        problem: 'credential path set in typed config but the file is '
            'missing: $explicit',
      );
    }

    // 2. OKA_<TARGET>_* env var — names a path, never a value.
    final envPath = environment[ref.envVarName];
    if (envPath != null && envPath.trim().isNotEmpty) {
      final src = CredentialSource(CredentialSourceKind.env, ref.envVarName);
      tried.add(src);
      final expanded = _expandTilde(envPath.trim());
      if (File(expanded).existsSync()) {
        return CredentialResolution(
          ref: ref,
          path: p.normalize(expanded),
          source: src,
          tried: tried,
        );
      }
    }

    // 3. Well-known location ~/.oka/credentials/<target>/<file>.
    final wellKnownSrc = CredentialSource(
      CredentialSourceKind.wellKnown,
      ref.wellKnownPath,
    );
    tried.add(wellKnownSrc);
    if (home.isNotEmpty) {
      final wellKnownFile = File(
        p.join(home, '.oka', 'credentials', ref.target,
            ref.wellKnownFileNameOrDefault),
      );
      if (wellKnownFile.existsSync()) {
        return CredentialResolution(
          ref: ref,
          path: p.normalize(wellKnownFile.path),
          source: wellKnownSrc,
          tried: tried,
        );
      }
    }

    return CredentialResolution(
      ref: ref,
      tried: tried,
      problem: 'no credential file found for "${ref.target}/${ref.kind}".',
    );
  }

  /// Resolves a **required** credential or throws
  /// [CredentialResolutionException] naming the candidates and the fix.
  CredentialResolution require(final CredentialRef ref) {
    final r = resolve(ref);
    if (r.ok) return r;
    throw CredentialResolutionException(ref: ref, resolution: r);
  }

  /// Remediation for [ref] — the "errors name the fix" half of the policy.
  static String remediationFor(final CredentialRef ref) =>
      'Place the credential file at ${ref.wellKnownPath} (gitignored when '
      'inside a repo), or set ${ref.envVarName} to a *path* (never a '
      'value), or set the credential path in typed config.';

  /// One doctor line per ref: `✅ target/kind → path (source)` or
  /// `❌ target/kind: not found` + tried candidates + fix. Never prints
  /// file contents — paths only.
  List<String> describePolicyLines(final Iterable<CredentialRef> refs) {
    final lines = <String>[];
    for (final ref in refs) {
      final r = resolve(ref);
      if (r.ok) {
        lines.add('✅ ${ref.target}/${ref.kind} → ${r.path}');
        lines.add('   source: ${r.source!.qualified}');
      } else {
        lines.add('❌ ${ref.target}/${ref.kind}: not found');
        for (var i = 0; i < r.tried.length; i++) {
          lines.add('   tried ${i + 1}: ${r.tried[i].qualified}');
        }
        lines.add('   fix: ${remediationFor(ref)}');
      }
    }
    return lines;
  }

  /// Expands a leading `~/` against [home] (`p.join` would otherwise
  /// replace the whole prefix with the absolute remainder).
  String _expandTilde(final String path) {
    if (!path.startsWith('~') || home.isEmpty) return path;
    final rest = path.substring(1);
    final relative =
        rest.startsWith(RegExp(r'^[/\\]')) ? rest.substring(1) : rest;
    return relative.isEmpty ? home : p.join(home, relative);
  }
}

const String _policyTemplateLine = 'ℹ️  credential paths resolve in order: '
    'typed config → OKA_<TARGET>_* env var (a *path*, never a value) → '
    '~/.oka/credentials/<target>/ — dart-defines carry app-visible build '
    'config only (ADR-0014 three-tier model)';

/// `OKA_*` env vars that are oka mechanics (cache root, SDK override,
/// verbosity, …), not credential path references — excluded from the
/// doctor's credential discovery. Tested constant.
const Set<String> nonCredentialOkaEnvVars = {
  'OKA_CACHE',
  'OKA_ANDROID_SDK',
  'OKA_VERBOSE',
  'OKA_MODE',
  'OKA_AAB',
  'OKA_NO_AUTO_INSTALL',
  'OKA_BUNDLETOOL_JAR',
};

final RegExp _okaEnvVarPattern = RegExp(r'^OKA_[A-Z][A-Z0-9_]*$');

/// Doctor credential-policy section (ADR-0014): the ordered policy as
/// lines, resolution status for known refs, `OKA_*` env discovery, the
/// well-known location, and the repo-hygiene verdict for every resolved
/// credential inside [projectPath].
///
/// Inject [environment]/[home] in tests. Never prints file contents —
/// paths only, values never.
List<String> doctorCredentialPolicyLines({
  final Map<String, String>? environment,
  final String? home,
  final String? projectPath,
  final List<CredentialRef> refs = const [],
}) {
  final env = environment ?? Platform.environment;
  final homeDir =
      home ?? env['HOME'] ?? env['USERPROFILE'] ?? '';
  final resolver = CredentialResolver(environment: env, home: homeDir);
  final lines = <String>[
    _policyTemplateLine,
  ];

  // Explicit refs (target packages composed by the caller).
  lines.addAll(resolver.describePolicyLines(refs));

  // Discovered: OKA_* env vars naming credential paths.
  final discovered = <CredentialRef>[
    for (final key in env.keys)
      if (key.startsWith('OKA_') &&
          !nonCredentialOkaEnvVars.contains(key) &&
          _okaEnvVarPattern.hasMatch(key))
        CredentialRef(
          target: key.substring(4).split('_').first.toLowerCase(),
          kind: key
              .substring(4)
              .split('_')
              .skip(1)
              .join('_')
              .toLowerCase(),
          envVar: key,
        ),
  ];
  if (discovered.isEmpty) {
    lines.add('ℹ️  no OKA_* credential env vars set');
  } else {
    lines.addAll(resolver.describePolicyLines(discovered));
  }

  // Well-known location state.
  if (homeDir.isNotEmpty) {
    final credRoot = Directory(p.join(homeDir, '.oka', 'credentials'));
    if (!credRoot.existsSync()) {
      lines.add('ℹ️  ~/.oka/credentials/ does not exist yet (nothing to '
          'resolve from the well-known location)');
    } else {
      for (final dir in credRoot.listSync().whereType<Directory>()) {
        final files = dir.listSync().whereType<File>().length;
        lines.add(
          files == 0
              ? 'ℹ️  ~/.oka/credentials/${p.basename(dir.path)}/ is empty'
              : '✅ ~/.oka/credentials/${p.basename(dir.path)}/ has '
                  '$files credential file(s)',
        );
      }
    }
  }

  // Legacy value-style vars — informational tier-rule note.
  if (env['OKA_STORE_PASS'] != null || env['OKA_KEY_PASS'] != null) {
    lines.add(
      '⚠️  OKA_STORE_PASS / OKA_KEY_PASS carry values; the ADR-0014 tier '
          'rule prefers env vars naming *paths* (keystore password '
          'indirection is legacy)',
    );
  }

  // Repo hygiene: resolved credentials inside the project must be ignored.
  if (projectPath != null) {
    for (final ref in [...refs, ...discovered]) {
      final r = resolver.resolve(ref);
      if (r.path == null) continue;
      final report = checkCredentialRepoHygiene(
        credentialPath: r.path!,
        projectPath: projectPath,
      );
      if (report.insideProject) lines.add(report.doctorLine);
    }
  }
  return lines;
}
