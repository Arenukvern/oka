/// The open store-key identity (ADR-0055).
///
/// A [StoreKey] is a typed name for an installation/distribution store:
/// `google-play`, `rustore`, `appgallery`, `apple-store`, `snapstore`,
/// `steam`, … — an **open set**. There is deliberately no enum: an enum
/// would lock the store list into this package and force every developer
/// targeting a store oka has never heard of to send a PR. Instead the key
/// is a validated string extension type, and stores are composed as
/// values ([StoreBinding] implementors, delivery variants, channel
/// capability declarations) without touching this package.
///
/// ```dart
/// const myStore = StoreKey('my-market');
/// // Compile-time safety, zero enumeration:
/// const play = storeKeyGooglePlay;
/// ```
///
/// Erasure caveat: a [StoreKey] IS its [String] at runtime — the type
/// distinction is static only, and `==` compares name values (String
/// equality). The const constructor cannot validate (it is the identity
/// of the open set); [StoreKey.of] is the checked form for dynamically
/// supplied names.
///
/// See also [okaStoreDefine] — the dart-define key under which a
/// delivery variant bakes its key into the compiled binary.
library;

/// The Dart-define key oka bakes a delivery variant's store key under
/// (ADR-0055). `Variant.applyTo` writes `OKA_STORE=<key.name>` into the
/// build context's dart defines, so the store identity reaches the
/// compiled binary and the app boot can verify its runtime binding
/// matches the composition (no two-masters drift between the delivery
/// matrix and the booted binding):
///
/// ```dart
/// final compiledStoreKey = const String.fromEnvironment(okaStoreDefine);
/// if (compiledStoreKey.isNotEmpty &&
///     binding.key.name != compiledStoreKey) { /* refuse to boot */ }
/// ```
const okaStoreDefine = 'OKA_STORE';

extension type const StoreKey(String name) implements String {
  /// A runtime-checked [StoreKey] for dynamically supplied names.
  ///
  /// The const constructor cannot validate — keys arrive typed from the
  /// composition. At a dynamic boundary (config files, CLI input), use
  /// this factory: it throws [ArgumentError] carrying the actionable
  /// validation error instead of shipping an invalid identity.
  factory StoreKey.of(String name) {
    final error = validate(name);
    if (error != null) throw ArgumentError(error);
    return StoreKey(name);
  }

  /// The name pattern for store keys: lowercase identifiers, digits,
  /// dashes, underscores — the same shape as oka target names, so keys
  /// compose into target names (`app-rustore`) and CLI args safely.
  static final RegExp namePattern = RegExp(r'^[a-z][a-z0-9_-]*$');

  /// Whether [name] is a valid store key.
  static bool isValidName(String name) => namePattern.hasMatch(name);

  /// A validation error for [name], or null when it is a valid key.
  ///
  /// Actionable by law: the message names the offending value, the rule,
  /// and a fixed example.
  static String? validate(String name) {
    if (name.isEmpty) {
      return 'store key is empty — keys are lowercase identifiers '
          '([a-z][a-z0-9_-]*), e.g. StoreKey("google-play").';
    }
    if (!isValidName(name)) {
      return 'invalid store key "$name": keys are lowercase identifiers '
          '([a-z][a-z0-9_-]*), e.g. StoreKey("google-play").';
    }
    return null;
  }

  /// This key's validation error, or null when valid (ADR-0055: deliveries
  /// validate composition before any tool runs).
  String? get validateError => StoreKey.validate(name);
}
