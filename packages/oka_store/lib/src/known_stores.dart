import 'store_key.dart';

/// Well-known [StoreKey] values — **convenience only, not a registry**
/// (ADR-0055).
///
/// These constants exist so the common stores read nicely in compositions.
/// They are not exhaustive and not authoritative: a store oka has never
/// heard of is composed with a plain `StoreKey('my-market')` and works
/// everywhere a key is accepted. Nothing in oka switches on these values.
const storeKeyGooglePlay = StoreKey('google-play');
const storeKeyRuStore = StoreKey('rustore');
const storeKeyAppGallery = StoreKey('appgallery');
const storeKeySamsungStore = StoreKey('samsung-store');
const storeKeyAmazonAppstore = StoreKey('amazon-appstore');
const storeKeyAppleStore = StoreKey('apple-store');
const storeKeySnapStore = StoreKey('snapstore');
const storeKeyWindowsStore = StoreKey('windows-store');
const storeKeyItch = StoreKey('itch');
const storeKeySteam = StoreKey('steam');
const storeKeyEpicGames = StoreKey('epic-games');
const storeKeyXsoulspaceWebsite = StoreKey('xsoulspace-website');

/// The store-neutral key ([NoopStoreBinding]'s default).
const storeKeyNoop = StoreKey('noop');
