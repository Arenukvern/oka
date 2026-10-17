import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  final hash = List.filled(64, 'a').join();
  test(
    'immutable policy exposes content identity with bounded cache lifetime',
    () {
      expect(WebBundleCachePolicy.immutable.headersFor(hash), {
        'Cache-Control': 'private, max-age=31536000, immutable',
        'ETag': '"$hash"',
      });
    },
  );
  test('exact, weak and listed tags match; stale tags miss', () {
    const policy = WebBundleCachePolicy.revalidate;
    expect(policy.headersFor(hash)['ETag'], '"$hash"');
    expect(policy.isNotModified(hash, 'W/"$hash"'), isTrue);
    expect(policy.isNotModified(hash, '"other", "$hash"'), isTrue);
    expect(policy.isNotModified(hash, '*'), isTrue);
    expect(policy.isNotModified(hash, '"old"'), isFalse);
    expect(policy.isNotModified(hash, null), isFalse);
  });
  test('no-store never returns not-modified', () {
    expect(WebBundleCachePolicy.noStore.isNotModified(hash, '*'), isFalse);
    expect(WebBundleCachePolicy.noStore.headersFor(hash), {
      'Cache-Control': 'no-store',
    });
    expect(
      () => WebBundleCachePolicy.revalidate.headersFor('bad'),
      throwsArgumentError,
    );
  });
}
