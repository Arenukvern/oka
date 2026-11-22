import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  group('StoreKey', () {
    test('valid names pass validation', () {
      expect(StoreKey.validate('google-play'), isNull);
      expect(StoreKey.validate('rustore'), isNull);
      expect(StoreKey.validate('my_market_2'), isNull);
      expect(const StoreKey('x').validateError, isNull);
    });

    test('invalid names produce actionable errors', () {
      expect(StoreKey.validate(''), contains('store key is empty'));
      expect(StoreKey.validate('Google-Play'), contains('invalid store key'));
      expect(StoreKey.validate('rust store'), contains('invalid store key'));
      expect(StoreKey.validate('-rust'), contains('invalid store key'));
      expect(const StoreKey('Bad').validateError, contains('invalid store'));
    });

    test('keys are const string values (open set, no enum)', () {
      const mine = StoreKey('my-market');
      expect(mine, 'my-market'); // implements String
      expect(mine == const StoreKey('my-market'), isTrue);
      expect(const StoreKey('google-play').name, 'google-play');
    });

    test('StoreKey.of validates at the dynamic boundary', () {
      expect(StoreKey.of('my-market').name, 'my-market');
      expect(() => StoreKey.of('Bad Key'), throwsArgumentError);
      expect(
        () => StoreKey.of(''),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('store key is empty'),
          ),
        ),
      );
    });

    test('okaStoreDefine is the baked identity key', () {
      expect(okaStoreDefine, 'OKA_STORE');
    });
  });

  group('StoreBinding', () {
    test('NoopStoreBinding defaults to the noop key', () {
      const binding = NoopStoreBinding();
      expect(binding.key, storeKeyNoop);
      expect(binding.key.name, 'noop');
    });

    test('a custom binding is a plain value implementing the interface', () {
      final binding = _TestBinding();
      expect(binding.key, const StoreKey('steam'));
    });
  });

  test('keys are composed values — new keys need no PR and no registry', () {
    const mine = StoreKey('vendor-x-store');
    expect(StoreKey.validate(mine.name), isNull);
    // Nothing switches on a well-known set: a novel key composes the
    // same way (ADR-0056 — no central registry; store packages carry
    // their own key constant).
    expect(mine != const StoreKey('google-play'), isTrue);
  });
}

final class _TestBinding implements StoreBinding {
  @override
  StoreKey get key => const StoreKey('steam');
}
