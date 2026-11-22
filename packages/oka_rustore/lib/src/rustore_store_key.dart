import 'package:oka_core/oka_core.dart';

/// The RuStore store key (ADR-0056: one store, one package — the key
/// lives beside its publish channel).
///
/// Convenience only, not a registry: a build-side composition may import
/// this constant; a runtime kernel should compose its own
/// `StoreKey('rustore')` (via `oka_core`) instead of depending on this
/// channel package just to name the store.
const storeKeyRuStore = StoreKey('rustore');
