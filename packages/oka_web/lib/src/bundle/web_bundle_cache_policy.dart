/// Cache policy is separate from verifying the response's artifact bytes.
enum WebBundleCachePolicy {
  noStore,
  revalidate,
  /// Only for verified bytes at an immutable content-addressed URL.
  immutable;

  Map<String, String> headersFor(String contentSha256) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(contentSha256)) {
      throw ArgumentError.value(
        contentSha256,
        'contentSha256',
        'Expected SHA-256',
      );
    }
    return switch (this) {
      noStore => {'Cache-Control': 'no-store'},
      revalidate => {
        'Cache-Control': 'private, max-age=0, must-revalidate',
        'ETag': '"$contentSha256"',
      },
      immutable => {
        'Cache-Control': 'private, max-age=31536000, immutable',
        'ETag': '"$contentSha256"',
      },
    };
  }

  /// Call only after current response bytes passed artifact verification.
  bool isNotModified(String contentSha256, String? ifNoneMatch) {
    final tag = headersFor(contentSha256)['ETag'];
    if (tag == null || ifNoneMatch == null) return false;
    return ifNoneMatch
        .split(',')
        .map((part) => part.trim())
        .any((value) => value == tag || value == 'W/$tag' || value == '*');
  }
}
