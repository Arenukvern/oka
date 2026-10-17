/// Stock frontend_server result envelope. A bare boundary is not completion.
class FrontendResult {
  const FrontendResult({
    required this.boundary,
    required this.path,
    required this.errors,
  });
  final String boundary;
  final String path;
  final int errors;
}

/// Parse the last request's complete terminal, preserving spaces in its path.
FrontendResult? parseFrontendResult(String output) {
  String? boundary;
  FrontendResult? result;
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('result ')) {
      boundary = line.substring(7).trim();
      result = null;
      continue;
    }
    if (boundary == null ||
        boundary.isEmpty ||
        !line.startsWith('$boundary ')) {
      continue;
    }
    final suffix = line.substring(boundary.length + 1);
    final split = suffix.lastIndexOf(' ');
    if (split < 1) continue;
    final errors = int.tryParse(suffix.substring(split + 1));
    if (errors == null || errors < 0) continue;
    result = FrontendResult(
      boundary: boundary,
      path: suffix.substring(0, split),
      errors: errors,
    );
  }
  return result;
}
