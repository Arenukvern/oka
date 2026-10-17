/// Opt-in HTTP policy for browser cross-origin isolation. Apply to served
/// documents/resources; this does not itself prove the browser is isolated.
/// Keep it independent of cache policy and compiler/renderer selection.
enum WebIsolationPolicy {
  none,
  requireCorp,
  credentialless;

  Map<String, String> get headers => switch (this) {
    none => const {},
    requireCorp => const {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
    credentialless => const {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'credentialless',
    },
  };
}
