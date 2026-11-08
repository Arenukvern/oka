/// Normalizes VM-service (and similar) observation strings for comparison.
String normalizeProbeObservation(String raw) {
  var s = raw.trim();
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'")))) {
    s = s.substring(1, s.length - 1);
  }
  return s;
}

/// True when [observed] satisfies [expect] from a [ProbeSpec].
///
/// Numeric observations (session ticks, fingerprints) compare as integers so
/// `999` does not satisfy `0`. Other values compare exactly after normalization.
bool probeObservationMatchesExpect(String observed, String expect) {
  final o = normalizeProbeObservation(observed);
  final e = expect.trim();
  final oInt = int.tryParse(o);
  final eInt = int.tryParse(e);
  if (oInt != null && eInt != null) return oInt == eInt;
  return o == e;
}

/// Receipt-level probe check for gates and agents.
bool probeResultSatisfiesSpec({
  required String observed,
  required String? expect,
  required bool hold,
  required String before,
}) {
  if (hold) {
    return probeObservationMatchesExpect(observed, before);
  }
  if (expect == null) return true;
  return probeObservationMatchesExpect(observed, expect);
}
