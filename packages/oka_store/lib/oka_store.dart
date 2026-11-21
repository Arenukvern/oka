/// The open store-key identity for oka (ADR-0055).
///
/// Stores are an **open set**: [StoreKey] is a validated string extension
/// type, not an enum. A new store is a new key value composed by the
/// project — never a PR to this package. [StoreBinding] is the typed
/// runtime half (one binding per app entrypoint; only the imported
/// backend compiles into the kernel), and the well-known keys are
/// convenience constants, not a registry.
///
/// This package is a leaf: it depends on nothing, so store-adjacent
/// ecosystems (e.g. monetization packages) can depend on the identity
/// without dragging in build machinery.
///
/// See also:
///
/// * `oka_core`'s [delivery/variant], which selects a binding's
///   entrypoint at build time.
/// * ADR-0055 (`docs/decisions/0055-buildable-pipeline-variant-channel.mdx`)
///   for the buildable × pipeline × variant × channel model and the
///   rejected alternatives (store enum, code-as-strings, `Oka.stores`).
library;

export 'src/known_stores.dart';
export 'src/store_binding.dart';
export 'src/store_key.dart';
