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
extension type const StoreKey(String name) implements String {
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
