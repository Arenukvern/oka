/// Redacts VM service auth path tokens from strings meant for shared diagnostics.
library;

const vmServiceAuthRedacted = '<redacted>';

/// VM service URIs embed an auth token in the path:
/// `http(s)://host:port/<token>=/` and `ws(s)://host:port/<token>=/ws`.
final _vmServiceUriToken = RegExp(
  r'((?:ws|wss|http|https)://[^/\s]+/)([^/\s?]+)(?:/ws)?',
  caseSensitive: false,
);

/// Replaces the auth path segment with [vmServiceAuthRedacted].
String redactVmServiceAuthInString(String input) {
  if (!_vmServiceUriToken.hasMatch(input)) return input;
  return input.replaceAllMapped(_vmServiceUriToken, (m) {
    final matched = m.group(0)!;
    final wsSuffix = matched.toLowerCase().endsWith('/ws') ? '/ws' : '';
    return '${m.group(1)}$vmServiceAuthRedacted$wsSuffix';
  });
}

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
