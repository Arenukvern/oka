# oka_store

The open store-key identity for oka deliveries (ADR-0055): typed,
const-constructible store keys with no store enumeration — a new store is
a new key value, never a package PR. Leaf package: depends on nothing.

```dart
import 'package:oka_store/oka_store.dart';

const Variant(
  key: storeKeyGooglePlay, // well-known convenience — not a registry
  entrypoint: 'lib/entrypoints/main_store_play.dart',
);
// A store oka has never heard of:
const mine = StoreKey('my-market');
// Runtime-checked form for dynamically supplied names:
final parsed = StoreKey.of(input);
```

`StoreBinding` is the typed runtime half (one binding per app entrypoint;
only the imported backend compiles into the kernel), and
`okaStoreDefine` is the dart-define key under which a delivery variant
bakes its store key into the compiled binary, so an app boot can verify
its runtime binding matches the composition. Store-adjacent ecosystems
(monetization packages) may depend on the identity without dragging in
oka's build machinery.
