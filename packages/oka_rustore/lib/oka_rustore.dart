/// The RuStore STORE package for oka (ADR-0055, ADR-0056): the RuStore
/// store key plus the distribution target and store-owned AAB readiness
/// gates.
///
/// A store is a distribution channel, never a platform (ADR-0056): a
/// RuStore build ships to any Android device that has the RuStore app —
/// including Huawei devices (the GMS-free build posture for those is
/// `oka_huawei`'s platform composition, not this package's business).
/// Runtime kernels should compose their own `StoreKey('rustore')` via
/// `oka_core` instead of depending on this channel package just to name
/// the store.
library;

export 'src/rustore_policy.dart';
export 'src/rustore_store_key.dart';
export 'src/rustore_target.dart';
