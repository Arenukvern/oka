# oka_huawei

The Huawei **device platform** package for
[oka](https://github.com/Arenukvern/oka) — the no-Gradle Flutter Android
build system. A Huawei device is a platform: a runtime that ships without
Google Play Services. `HuaweiBuildVariant` is the GMS-excluding Android
build composition — GMS coordinates (Play Services, Billing, Ads,
Firebase) are dropped from `extraDeps`, and a step *requiring* a
GMS-provided artifact fails validation at composition time, before any
tool runs.

A platform is **not** a store (ADR-0056 — the line is thin but real): a
Huawei device carries AppGallery, RuStore, and sideloaded APKs alike. The
store halves live in their own packages —
[oka_app_gallery](../oka_app_gallery) (AppGallery Connect channel + key)
and [oka_rustore](../oka_rustore) (RuStore channel + key). Store channels
declare their platform requirements at composition time
(`requiredOverlays`/`prohibitedOverlays`): AppGallery prohibits the `gms`
overlay, Play requires it — the platform never names a store.

## 30-second quickstart

Compose the GMS-free platform posture onto any Android pipeline:

```dart
import 'package:oka_android/oka_android.dart';
import 'package:oka_huawei/oka_huawei.dart';

const variant = HuaweiBuildVariant(
  android: AndroidBuild(packageName: 'dev.example.app'),
  overrides: PipelineOverrides(
    extraDeps: [
      'androidx.core:core-ktx:1.13.1',              // kept (not GMS)
      'com.android.billingclient:billing-ktx:7.0.0', // excluded (GMS)
    ],
  ),
);

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: Oka(
        pipelines: [
          // Same AndroidBuild you already have, GMS-free overrides applied.
          AndroidPipeline(
            config: variant.android,
            overrides: variant.gmsFreeOverrides,
          ),
        ],
        // Stores compose as deliveries/channels — see oka_app_gallery
        // and oka_rustore.
      ),
    );
```

`variant.gmsFreeExtraDeps` and `variant.excludedGmsDeps` are inspectable
data: exactly which coordinates survived and which were dropped, printed
by diagnostics and assertable in tests.

## Why composition-time, not build-time

A GMS coordinate in a GMS-free artifact either fails at runtime on the
device or silently drags the Play dependency graph into a non-Play build.
oka refuses the composition BEFORE any tool runs: in a pipeline composed
from this variant the GMS-providing step is absent by construction, so
any step requiring `gms-dep:<coordinate>` fails the standard artifact
validator at composition time.

## Conformance

The exclusion law is asserted in this package's tests: coordinate
classification via the `oka_android` seam (`isGmsCoordinate`), filtered
overrides, and the required-artifact failure — all offline, no tooling
invoked.

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions)
(ADR-0055 delivery matrix, ADR-0056 the store/platform line).
