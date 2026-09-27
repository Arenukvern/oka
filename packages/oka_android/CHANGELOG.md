## 0.5.0

### Fixed

- Release builds no longer fall back to the debug `flutter.jar` when the
  release jar is missing: the fallback shipped a debug JIT engine with a
  release AOT snapshot, producing apps that hang on the splash screen and
  never run Dart `main()`. Missing jars trigger `flutter precache --android`
  once; a still-missing jar fails the build.

### Changed

- Engine artifact resolution is mode-correct: debug → `android-<abi>`,
  profile → `android-<abi>-profile`, release → `android-<abi>-release`
  (`engineVariantForMode`, `engineArtifactDirForVariant`). The `release`
  boolean parameters on `findFlutterJar` / `extractLibflutter` /
  `extractLibflutterForAbis` were replaced by the variant string, and
  `engineArtifactDirForAbi` was renamed to `engineArtifactDirForVariant`.
- `fingerprintInputs` consumers: `flutter-assemble` and `release-aot`
  fingerprints now include path-dependency sources (`pathDependencyInputs`)
  and `buildArgs`.

## 0.2.0

- Add a composable AVD diagnostics provider with stored configuration,
  userdata/snapshot measurements and recorded session links.

- Join the complete package release train with compatible `0.2.0` internal
  dependency constraints.

## 0.1.6

- Dependency-plan dry-run (`oka explain --deps`), artifact comparison gate
  (`oka compare`), single-step probe support (ADR-0007/0008).
- Conditional gradle dependency dedup (if/else variants collapse to the
  gradle default branch).
- Deterministic packaging: sorted d8 inputs and sorted zip entry order.
- archive ^4 support.

## 0.1.5

- Package split from the oka CLI (ADR-0006).
