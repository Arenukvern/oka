/// Launch failure signatures as data (ADR-0029 D5).
///
/// Every incident write-up may add rows here; `oka run device`,
/// `oka run verify`, and evidence docs then share one source of truth. The
/// 2026-09-27 splash-hang postmortem contributed the first entries.
///
/// Extension contract: targets accept additional signatures
/// (`VerifyTarget(extraFailureSignatures: [...])`), so a project can teach
/// the ladder about its own failure modes without touching oka.
library;

/// One known launch-failure signature: the logcat needle, what it means,
/// and the fix. [evidence] points at the incident write-up that recorded it.
class FailureSignature {
  const FailureSignature({
    required this.id,
    required this.needle,
    required this.cause,
    required this.fix,
    this.evidence = '',
  });

  final String id;
  final String needle;
  final String cause;
  final String fix;
  final String evidence;

  Map<String, Object?> toJson() => {
    'id': id,
    'needle': needle,
    'cause': cause,
    'fix': fix,
    if (evidence.isNotEmpty) 'evidence': evidence,
  };
}

/// Signatures oka ships, most specific first (scanning reports every match;
/// order only affects display).
const builtinFailureSignatures = <FailureSignature>[
  FailureSignature(
    id: 'vm-snapshot-invalid',
    needle: 'VM snapshot invalid and could not be inferred from settings',
    cause:
        'AOT snapshot compiled against an inconsistent pub resolution (or a '
        'snapshot/engine version skew) — the engine refuses to boot the VM',
    fix:
        're-run `flutter pub get` (verify it succeeds against the resolved '
        'workspace) and rebuild release so the AOT is regenerated against '
        'the current resolution',
    evidence:
        'docs/evidence/android-release-engine-pairing-2026-09-27.mdx',
  ),
  FailureSignature(
    id: 'dart-vm-init-failed',
    needle: 'Could not create Dart VM instance',
    cause: 'Dart VM initialization failed — snapshot or engine data invalid',
    fix:
        'inspect the flutter error lines just above in logcat; rebuild both '
        'engine natives and the AOT from the same Flutter SDK',
    evidence:
        'docs/evidence/android-release-engine-pairing-2026-09-27.mdx',
  ),
  FailureSignature(
    id: 'fatal-signal',
    needle: 'Fatal signal',
    cause: 'Native crash (SIGSEGV/SIGABRT) in the app process',
    fix:
        'pull the tombstone frame #00 from `adb logcat -b crash` and match '
        'it against the failing native library',
  ),
  FailureSignature(
    id: 'width-zero',
    needle: 'Width is zero',
    cause:
        'The Flutter renderer never received a surface — the app is stuck '
        'before the first frame (typical of an engine/snapshot mismatch or '
        'a wedged GPU stack)',
    fix:
        'run `oka run verify` — the pairing rung and dart-main beacon '
        'separate "main never ran" from "main ran but never rendered"',
    evidence:
        'docs/evidence/android-release-engine-pairing-2026-09-27.mdx',
  ),
  FailureSignature(
    id: 'fatal-exception',
    needle: 'FATAL EXCEPTION',
    cause: 'Java/Kotlin crash on the main thread',
    fix: 'read the stack right below this line in logcat',
  ),
  FailureSignature(
    id: 'unhandled-dart-exception',
    needle: 'Unhandled Exception',
    cause: 'Dart exception escaped the zone',
    fix: 'read the Dart stack right below this line in logcat',
  ),
  FailureSignature(
    id: 'missing-class',
    needle: 'NoClassDefFoundError',
    cause:
        'runtime class missing from the DEX — a dependency the code needs '
        'was not packaged (R8 kept too little, or a jar never landed)',
    fix:
        'declare the missing classes via `r8Rules` / `extraDeps` and '
        'rebuild; check the R8 mapping for the class',
  ),
  FailureSignature(
    id: 'registrant-missing',
    needle: 'could not find or invoke the GeneratedPluginRegistrant',
    cause:
        'plugin registrant failed to load — every plugin is silently '
        'unregistered',
    fix: 'check plugin packaging output; re-run `oka build` verbosely',
  ),
  FailureSignature(
    id: 'plugin-register-failed',
    needle: 'Error registering plugin',
    cause: 'a single plugin failed registration (often a version skew)',
    fix: 'read which plugin in the same log line',
  ),
  FailureSignature(
    id: 'channel-error',
    needle: 'channel-error',
    cause: 'Dart called a platform channel whose handler is not registered',
    fix:
        'usually follows `plugin-register-failed`/`registrant-missing`; '
        'fix the registration failure first',
  ),
  FailureSignature(
    id: 'pigeon-channel-missing',
    needle: 'Unable to establish connection on channel',
    cause: 'platform channel handler missing',
    fix: 'verify the plugin/host code registers the channel before use',
  ),
  FailureSignature(
    id: 'system-anr',
    needle: 'Application Not Responding',
    cause:
        'the main thread never returned to the system — the app is wedged '
        'in startup (typical of a synchronous block before the first frame)',
    fix:
        'on emulators first check device health (`oka run verify` reports '
        'inconclusive-device) — systemui ANRs poison evidence',
    evidence:
        'docs/evidence/android-release-engine-pairing-2026-09-27.mdx',
  ),
];

/// A matched signature in a log dump.
class SignatureMatch {
  const SignatureMatch(this.signature, this.line);
  final FailureSignature signature;

  /// The log line containing the needle (trimmed), for direct evidence.
  final String line;

  Map<String, Object?> toJson() => {
    ...signature.toJson(),
    'log_line': line,
  };
}

/// Scans [log] (case-insensitive) for [signatures]. Pure — unit-tested
/// without a device.
List<SignatureMatch> scanFailureSignatures(
  final String log, {
  final List<FailureSignature> signatures = builtinFailureSignatures,
}) {
  final lowered = log.toLowerCase();
  final matches = <SignatureMatch>[];
  for (final s in signatures) {
    final idx = lowered.indexOf(s.needle.toLowerCase());
    if (idx == -1) continue;
    // Report the full original log line containing the needle.
    final lineStart = log.lastIndexOf('\n', idx) + 1;
    var lineEnd = log.indexOf('\n', idx);
    if (lineEnd == -1) lineEnd = log.length;
    matches.add(
      SignatureMatch(s, log.substring(lineStart, lineEnd).trim()),
    );
  }
  return matches;
}
