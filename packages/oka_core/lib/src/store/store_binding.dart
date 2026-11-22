import 'package:meta/meta.dart';

import 'store_key.dart';

/// The store-neutral key: the identity that means "no store" —
/// [NoopStoreBinding]'s default and the dev/store-less posture.
const storeKeyNoop = StoreKey('noop');

/// A typed binding that names the store a build is composed for
/// (ADR-0055, ADR-0056).
///
/// The binding is the *runtime* half of the store identity: an app whose
/// entrypoint imports exactly one binding compiles only that store's
/// backend code into its AOT kernel (the per-store-entrypoint mechanism).
/// The *build* half is the delivery variant that selects the entrypoint.
///
/// Extensions are domain-specific and stay out of oka: monetization
/// extends the contract with a purchase-provider factory
/// (`MonetizationStoreBinding` in xsoulspace_monetization_foundation) —
/// store identity is not about monetization, and this package must never
/// grow payment vocabulary. Per ADR-0056 the ecosystem contract is the
/// STRING key name (joined to oka by the [okaStoreDefine] define), so a
/// monetization package needs no oka dependency at all.
///
/// ```dart
/// final class RuStoreBinding implements StoreBinding {
///   const RuStoreBinding();
///   @override
///   StoreKey get key => const StoreKey('rustore');
/// }
/// ```
abstract interface class StoreBinding {
  /// The open store key this binding names.
  StoreKey get key;
}

/// The no-op binding: the store-neutral identity used by development and
/// store-less builds.
///
/// Composing `NoopStoreBinding` means "no store backend is compiled in" —
/// purchase-provider factories resolve to null and callers fall back to
/// their own no-op implementations.
@immutable
class NoopStoreBinding implements StoreBinding {
  /// Const constructor; defaults to the shared `noop` key.
  const NoopStoreBinding([this.key = storeKeyNoop]);

  @override
  final StoreKey key;

  @override
  String toString() => 'NoopStoreBinding(${key.name})';
}
