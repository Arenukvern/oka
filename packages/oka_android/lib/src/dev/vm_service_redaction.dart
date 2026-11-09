/// Redacts VM service auth path tokens from strings meant for shared diagnostics.
library;

const vmServiceAuthRedacted = '<redacted>';

final _loopbackVmServiceUri = RegExp(
  r'((?:ws|wss|http|https)://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/)([^/\s?]+)(?:/ws)?',
  caseSensitive: false,
);

/// VM-service auth path segments are base64-ish and end with `=`.
final _vmServiceAuthPathSegment = RegExp(r'^[A-Za-z0-9+/_.-]+=$');

/// Replaces loopback VM-service auth path segments with [vmServiceAuthRedacted].
String redactVmServiceAuthInString(String input) =>
    input.replaceAllMapped(_loopbackVmServiceUri, (m) {
    final segment = m.group(2)!;
    if (!_vmServiceAuthPathSegment.hasMatch(segment)) {
      return m.group(0)!;
    }
    final wsSuffix = m.group(0)!.toLowerCase().endsWith('/ws') ? '/ws' : '';
    return '${m.group(1)}$vmServiceAuthRedacted$wsSuffix';
    });

/// Deep-walks JSON-like structures and redacts VM service URIs in strings.
Object? redactVmServiceAuthDeep(Object? value) {
  if (value is String) {
    return redactVmServiceAuthInString(value);
  }
  if (value is List) {
    return value.map(redactVmServiceAuthDeep).toList(growable: false);
  }
  if (value is Map) {
    return value.map(
      (k, v) => MapEntry(k, redactVmServiceAuthDeep(v)),
    );
  }
  return value;
}
