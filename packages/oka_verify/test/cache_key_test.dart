import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

void main() {
  const context = CacheKeyContext(
    sdkVersion: '3.13.4',
    packageConfigHash: 'config-hash',
    contractVersion: '1',
  );

  String key({
    List<String> closure = const <String>['/w/lib/a.dart'],
    Map<String, String> hashes = const <String, String>{'/w/lib/a.dart': 'aaa'},
    CacheKeyContext ctx = context,
  }) =>
      computeSuiteKey(closure: closure, fileHashes: hashes, context: ctx);

  test('the same inputs produce the same key', () {
    expect(key(), key());
  });

  test('a change in the closure changes the key', () {
    final before = key();
    final after = key(
      hashes: const <String, String>{'/w/lib/a.dart': 'bbb'},
    );
    expect(after, isNot(before));
  });

  test('a file outside the closure does not change the key', () {
    final before = key();
    final after = key(
      hashes: const <String, String>{
        '/w/lib/a.dart': 'aaa',
        '/w/lib/unrelated.dart': 'zzz',
      },
    );
    expect(after, before);
  });

  test('the SDK version is part of the key', () {
    final before = key();
    final after = key(
      ctx: const CacheKeyContext(
        sdkVersion: '3.14.0',
        packageConfigHash: 'config-hash',
        contractVersion: '1',
      ),
    );
    expect(after, isNot(before));
  });

  test('the package configuration is part of the key', () {
    final before = key();
    final after = key(
      ctx: const CacheKeyContext(
        sdkVersion: '3.13.4',
        packageConfigHash: 'other-config-hash',
        contractVersion: '1',
      ),
    );
    expect(after, isNot(before));
  });

  test('the bootstrap contract version is part of the key', () {
    final before = key();
    final after = key(
      ctx: const CacheKeyContext(
        sdkVersion: '3.13.4',
        packageConfigHash: 'config-hash',
        contractVersion: '2',
      ),
    );
    expect(after, isNot(before));
  });

  test('a deleted file invalidates like a changed one', () {
    final before = key();
    final after = key(hashes: const <String, String>{});
    expect(after, isNot(before));
    // A missing file hashes as the missing marker, so "the file is gone"
    // and "the file hashes as gone" are the same fact.
    expect(
      after,
      computeSuiteKey(
        closure: const <String>['/w/lib/a.dart'],
        fileHashes: const <String, String>{
          '/w/lib/a.dart': missingFileHash,
        },
        context: context,
      ),
    );
  });

  test('the closure order does not change the key', () {
    final a = key(
      closure: const <String>['/w/lib/a.dart', '/w/lib/b.dart'],
      hashes: const <String, String>{
        '/w/lib/a.dart': 'aaa',
        '/w/lib/b.dart': 'bbb',
      },
    );
    final b = key(
      closure: const <String>['/w/lib/b.dart', '/w/lib/a.dart'],
      hashes: const <String, String>{
        '/w/lib/a.dart': 'aaa',
        '/w/lib/b.dart': 'bbb',
      },
    );
    expect(a, b);
  });
}
