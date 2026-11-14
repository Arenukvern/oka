# Changelog

<!-- markdownlint-disable MD052 -->

All notable changes to the Oka project will be documented in this file.

## [0.10.1](https://github.com/Arenukvern/oka/compare/v0.10.0...v0.10.1) (2026-11-14)


### Bug Fixes

* **android:** clarify forward release result and hermetic spawn test ([55a358b](https://github.com/Arenukvern/oka/commit/55a358b9a56b289aad7c250807663b7838a584ec))
* **core:** keep workspace root helper out of published oka_core ([d02b2ee](https://github.com/Arenukvern/oka/commit/d02b2eeb142b7414f643a6bde1c0888a480f8cc2))
* **init:** regression test for defaultSteps run_session manifest ([859b812](https://github.com/Arenukvern/oka/commit/859b8126d3f1c98c0912d065b3d5036f79c2fae9))


### Documentation

* align oka_process publish docs with OIDC train ([64e1c47](https://github.com/Arenukvern/oka/commit/64e1c47dd9211448f42d828d94d8e5406fa8ac46))

## [0.10.0](https://github.com/Arenukvern/oka/compare/v0.9.1...v0.10.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* **oka_update:** oka_update exposes universal_automation_interface types in its public API — SurfaceActionDescriptor on LiveVerb.descriptor and liveVerbDescriptors (packages/oka_update/lib/src/live/agent.dart, re-exported from packages/oka_update/lib/oka_update.dart). Downstream apps must allow interface ^0.4.0. oka_harness lib does not export interface types (packages/oka_harness/lib/).

### Features

* **android:** clarify runner-session pid vs spawn handle ownership ([f339a35](https://github.com/Arenukvern/oka/commit/f339a359dc202896ab1591be7d80469e1a3145a7))
* **android:** record forwardReleased on attach spawn failure ([f7cbd8f](https://github.com/Arenukvern/oka/commit/f7cbd8f33afed606896a2cce9fae754725840f40))
* **artifacts:** bounded retention — snapshots truncate the chain; sweep GC ([fc88224](https://github.com/Arenukvern/oka/commit/fc8822470dfe1ab094947a1526f13e759e781b4d))
* **harness:** cooperative oka dev android stop with truthful receipt ([7515324](https://github.com/Arenukvern/oka/commit/75153244c0357b04f730707c95bae98b8b29b7fd))
* **linux L0:** desktop dev doctor + Flutter linux JIT gates ([2679790](https://github.com/Arenukvern/oka/commit/26797901714ff7c3cd794c139273837191d51472))
* **linux L0:** doctor diagnostics + Flutter desktop dev gates ([2b43ffd](https://github.com/Arenukvern/oka/commit/2b43ffd5f719109966112589c811e1297e1ca469))
* **oka_devices:** add R2 declarative device/run spec types ([56dcfc3](https://github.com/Arenukvern/oka/commit/56dcfc35b563bae3ef22dd65bef1b98973ce1415))
* **oka_devices:** R2 declarative device/run spec types ([3477fb8](https://github.com/Arenukvern/oka/commit/3477fb8ad96bd96750a7cdbe2959f818e55d6029))
* **update:** S2 slot registry and in-process slot swap (ADR-0035) ([a454cdc](https://github.com/Arenukvern/oka/commit/a454cdc7d1fb972477e20ef71dc36b3161b31675))


### Bug Fixes

* **android-dev:** attach fail-fast and bounded handshake diagnostics ([2b2cf12](https://github.com/Arenukvern/oka/commit/2b2cf125fc7ca4d1e800023a470bce834fe07ec8))
* **android-dev:** attach via port flags not debug-url (b946 evidence) ([a92e818](https://github.com/Arenukvern/oka/commit/a92e818061de37e9188eada5c41a3d855596e5bc))
* **android-dev:** bounded teardown receipt and attach debug-url ([a7d7180](https://github.com/Arenukvern/oka/commit/a7d71801affce8ac39c73b8a1abea1dcf8ac482a))
* **android-dev:** pidof exit 1 absence after shell sentinel ([ba61812](https://github.com/Arenukvern/oka/commit/ba618121133d0bb43809ac3194fd9a154e6ac288))
* **android-dev:** SDK teardown with owned-forward and honest quit ([cb672b7](https://github.com/Arenukvern/oka/commit/cb672b7bca8198c57a05b548443980efabf5d679))
* **android-dev:** sidecar identity via discovery snapshot at stop ([1b7f18f](https://github.com/Arenukvern/oka/commit/1b7f18fa48f2c87096e023ce59478d30737e69f8))
* **android-dev:** teardown budget timing and attach device debug URL ([ac745d9](https://github.com/Arenukvern/oka/commit/ac745d9f44f5aa5f0d0bcea31ea0be16615d078c))
* **android:** attach handshake race precheck and bounded diagnostic ring ([a71e340](https://github.com/Arenukvern/oka/commit/a71e340016b4bd2cbd28c6481a4e05cb38e1156d))
* **android:** CI fatal-infos, safe handshake diagnostics, test support ([e021187](https://github.com/Arenukvern/oka/commit/e02118704844fb53f65ef6313fdbf89b4eb62812))
* **android:** fail-closed control quit when spawn binding is unknown ([1ab510f](https://github.com/Arenukvern/oka/commit/1ab510f887f83c15c79281c4679d59aa0245e301))
* **android:** honest stop receipt, stale-port guard, CI harness lint ([469b0d5](https://github.com/Arenukvern/oka/commit/469b0d55298035c9e896a49474df89a06680380b))
* **android:** pidof wait uses teardown budget Stopwatch ([dd6bf55](https://github.com/Arenukvern/oka/commit/dd6bf557dbe9240496e57f397c3ac59a9c6fc7ef))
* **android:** redact only loopback VM auth tokens in diagnostics ([825a68b](https://github.com/Arenukvern/oka/commit/825a68b75fdd1ab20f03db30e3e7add9b7c527bf))
* **android:** separate DDS port from oka-owned adb forward on attach ([ce67694](https://github.com/Arenukvern/oka/commit/ce6769483b7a4f1877ede7bab11c9e690df90236))
* bounded branding, release train workspace deps, dev linux slice ([7a2d5ed](https://github.com/Arenukvern/oka/commit/7a2d5ed3a4adef278f9266d9a04553a187e5c7ff))
* branding, release train workspace deps, dev linux slice ([#14](https://github.com/Arenukvern/oka/issues/14)) ([0ffa098](https://github.com/Arenukvern/oka/commit/0ffa098e7479ef18b01b24828e9857cf952cc9d9))
* **ci:** address OIDC workflow env and add publish contracts ([ddbf256](https://github.com/Arenukvern/oka/commit/ddbf2569d3570e0ef16b3593d11ce4923645684e))
* **ci:** reap yes fixtures deterministically; strengthen harness teardown ([32a1b69](https://github.com/Arenukvern/oka/commit/32a1b69f9f9980d3e67d7c772cf2c7f0a99d485c))
* **ci:** refresh pub.dev OIDC token per package publish ([6edd33d](https://github.com/Arenukvern/oka/commit/6edd33d0e4cadc9de79a2e1ae567bd63718b01c9))
* **ci:** refresh pub.dev OIDC token per package publish ([3e56cbd](https://github.com/Arenukvern/oka/commit/3e56cbd3bb87030db41df7e71298280db061e853))
* **ci:** stop init tests from racing on Directory.current ([0823813](https://github.com/Arenukvern/oka/commit/0823813efdbbf0a1c2bb27b1f446200d8736f44b))
* **ci:** stop init tests from racing on Directory.current ([6e0d6bf](https://github.com/Arenukvern/oka/commit/6e0d6bf5303c3f6ddc90dd207e15982f0890f7ab))
* **core:** age out stale .oka_cache/build mode dirs (7d) in hygiene pass ([98eea0a](https://github.com/Arenukvern/oka/commit/98eea0a2527e2b90f7dbf9cb600147058c8a2d7b))
* **core:** reap oka_* produce temp dirs at fetch; run store GC at start ([6606739](https://github.com/Arenukvern/oka/commit/66067392407ee1fd97fb90fd5a82253ed5e9621c))
* **example:** commit pubspec_overrides.yaml and broaden override guard ([9b6dfc0](https://github.com/Arenukvern/oka/commit/9b6dfc0b8bd1229b7f4fbaadfba324c91acf8be2))
* **example:** keep path overrides in pubspec.yaml for CI ([1069699](https://github.com/Arenukvern/oka/commit/10696996a087bfe026847f64292b2365402539cb))
* **example:** path-override every reachable train package so release PRs resolve pre-publish ([a675e84](https://github.com/Arenukvern/oka/commit/a675e848f4b3f52687612a320cf2c8fbc494c061))
* **example:** path-override reachable train packages for release resolution ([b88dc27](https://github.com/Arenukvern/oka/commit/b88dc27d99aaa9d67c8fa7aa71368a6f3ac89caa))
* **harness:** Android dev session argv and defaultSteps run_session parity ([8b353f9](https://github.com/Arenukvern/oka/commit/8b353f90d5c60f276932a9e0edb8b6444040c54f))
* **harness:** compat stopCooperatively without nullable spawn pid ([f41b0d6](https://github.com/Arenukvern/oka/commit/f41b0d64ffb02e4d2e51adf3608e43746809f470))
* **harness:** route Android dev through oka dev android ([7416849](https://github.com/Arenukvern/oka/commit/7416849a14cf817217e6fd84c305d5f1529b7c41))
* **linux L0:** assert VM probe expects; owned teardown and signals ([1175bd9](https://github.com/Arenukvern/oka/commit/1175bd992b55def149b259282cb91d69d1821eae))
* **linux L0:** CI gate wiring, analyze clean, VM restart state proof ([44a52a3](https://github.com/Arenukvern/oka/commit/44a52a305c112c5f90672b75040fadcdb50e04e9))
* **linux L0:** invoke oka_run_dev.dart directly on CI checkout layout ([bb6c4ce](https://github.com/Arenukvern/oka/commit/bb6c4ce442bfb2b3e0d36d564d5c7618253081a9))
* **linux L0:** per-session subreaper, ownership ledger, startup abort ([22b2520](https://github.com/Arenukvern/oka/commit/22b2520d8dfa0cb3316a336ccd03fc9c6a8e95ea))
* **linux L0:** public run dev path and owned-tree teardown ([1e3a73b](https://github.com/Arenukvern/oka/commit/1e3a73b9961fb6cbbcc27444fbebb47144c267ce))
* **linux L0:** subreaper drain setsid adoptees before supervisor exit ([fc8cdb6](https://github.com/Arenukvern/oka/commit/fc8cdb6a48a0dfb7a4422b8667b834b44ca0d8ba))
* **linux L0:** UA review — doctor probes, Dart gates, CI session race ([88805dd](https://github.com/Arenukvern/oka/commit/88805dd05373e95119060ce30019c9c81e0e2664))
* **linux:** adversarial drain test uses synthetic proc; shard CI ([7c2028e](https://github.com/Arenukvern/oka/commit/7c2028ed9b936168f616ddb074103f48c345106e))
* **linux:** fail-closed /proc scan, budget, and drain verification ([173cb01](https://github.com/Arenukvern/oka/commit/173cb017db2449232dee661099758e0917d179cc))
* **linux:** harden subreaper drain with /proc fallback and diagnostics ([2a9519f](https://github.com/Arenukvern/oka/commit/2a9519fa10bb8d7414977bab652058341e596c20))
* **linux:** stop ps churn under child subreaper during drain ([6a406bc](https://github.com/Arenukvern/oka/commit/6a406bc9ac80e45d5c2b7f3de7f4a7c76a4cddb3))
* **linux:** UA fourth-review supervisor drain ack and safe fixtures ([bf21980](https://github.com/Arenukvern/oka/commit/bf219800ea2af87c28c2c8306c126ff37fa1db32))
* **oka_devices:** enforce DDS port 0 when oka owns host forward ([41efe1a](https://github.com/Arenukvern/oka/commit/41efe1a8ddb5fe9c413899b877a4433fed031e96))
* **oka_update:** require universal_automation_interface ^0.4.0 ([30d0a88](https://github.com/Arenukvern/oka/commit/30d0a88bdbb642de42afb835a69584b2f7b8db1b))
* **review:** archive ^4.6.0 zip stamp + metadata/TZ regression tests ([84b5427](https://github.com/Arenukvern/oka/commit/84b5427ab69a58acfc9137625c01cd907dd3a811))
* **review:** platform-scoped flutter_assets discovery ([#16](https://github.com/Arenukvern/oka/issues/16)) ([ce55950](https://github.com/Arenukvern/oka/commit/ce55950e4c87edd773ec8338ce0b91c8f6d38e13))
* **review:** release-please non-train version guard + zip determinism ([6243e44](https://github.com/Arenukvern/oka/commit/6243e44aff2ddf2a0a64a6d19d286981401d5953))
* **review:** Unix-0 zip stamp for TZ-stable DOS fields ([c33e31c](https://github.com/Arenukvern/oka/commit/c33e31c9bd5d6f3f5e441ccbf82e1fc7ac70029d))


### Documentation

* **android:** cite Flutter 3.47.5 for --dds-port default ([78505df](https://github.com/Arenukvern/oka/commit/78505df3f379bf5966d45608ccc4e31b928abeba))
* **evidence:** note 1175bd9 supersedes false-green bc718886 ([641daad](https://github.com/Arenukvern/oka/commit/641daad071cbf870ef783b51f2a1ba503384aeef))
* **evidence:** pin green CI 42526360936 on 641daad ([de3207e](https://github.com/Arenukvern/oka/commit/de3207e127d106a225f58a1a589ee77b1e15ea44))
* **evidence:** pin green Linux L0 CI run 42524543199 ([bc71888](https://github.com/Arenukvern/oka/commit/bc7188867409c90833949fc2e94fad43383cac4e))
* **oka_devices:** add README for pub.dev dry-run gate ([622eb7a](https://github.com/Arenukvern/oka/commit/622eb7ac9ea2b94e9baf4c8c8188c894c33a888e))

## [0.9.1](https://github.com/Arenukvern/oka/compare/v0.9.0...v0.9.1) (2026-10-27)


### Bug Fixes

* **ci:** hosted consumer uses pub.dev train only ([4f9c329](https://github.com/Arenukvern/oka/commit/4f9c329da21d2d0ca1b48c25956ba34523b764b3))
* **release:** RP-managed follower changelogs for pub.dev validation ([ee4e367](https://github.com/Arenukvern/oka/commit/ee4e3674575beae46291d48319b0c584f05b17ad))


### Documentation

* document dart analyze --fatal-infos local gate ([c7117a7](https://github.com/Arenukvern/oka/commit/c7117a772cec434f73ad7040974267d364c78651))
* fix publishing runbook path in contribution guide ([8fc15de](https://github.com/Arenukvern/oka/commit/8fc15dec504763288a64020a46417bf64d5579dd))

## [0.9.0](https://github.com/Arenukvern/oka/compare/v0.8.1...v0.9.0) (2026-10-27)


### Features

* **oka_process:** ADR-0052 owned POSIX process sessions (Linux/macOS) ([c5bdeef](https://github.com/Arenukvern/oka/commit/c5bdeefc830fa66abc9681114daf527838d0e82f))
* **oka_process:** ADR-0052 owned POSIX sessions package skeleton ([6dd6884](https://github.com/Arenukvern/oka/commit/6dd6884faa1e02555f040e85d4a35113b118eec1))


### Bug Fixes

* locks ([83cc8d6](https://github.com/Arenukvern/oka/commit/83cc8d6611511c53651fb7e4dc88d60acdfa2282))
* **oka_process:** allow settle during stop; mirror UA term/grace/kill/settle order ([3c4ff36](https://github.com/Arenukvern/oka/commit/3c4ff368591499d6b41f66fc7c0ac948c90f907d))
* **oka_process:** fail closed when control dir chmod 700 fails ([334ae92](https://github.com/Arenukvern/oka/commit/334ae92b27f1d7c57084edebee86907d350240f9))
* **oka_process:** settle stop when kill command sent on control channel ([9b00b2c](https://github.com/Arenukvern/oka/commit/9b00b2c15bdc655b80fa4c30f509ac3e85bacf03))
* **oka_verify:** abort frontend server on compile budget timeout ([afeb33b](https://github.com/Arenukvern/oka/commit/afeb33b18350a6b4a86aa1349d097b7424287a30))
* **release:** accept list --publish and align release_train fixtures ([4b052e9](https://github.com/Arenukvern/oka/commit/4b052e93299c071f59dec55f090de3e2133e0601))


### Documentation

* **oka_process:** AOT must set OWNED_SESSION_P1_LEADER ([38e8dfb](https://github.com/Arenukvern/oka/commit/38e8dfb48844953eb8494e9160476a5f4b58e4df))
* **oka_process:** pin normative p1 contract at dfp 2f9ce9b1 ([3043eb4](https://github.com/Arenukvern/oka/commit/3043eb432e5b6a561466a6d7a434caf405679194))
* point the codemap navigation CLI at the rust binary ([292bdf2](https://github.com/Arenukvern/oka/commit/292bdf2bc32285958a926c38c7570517108da85b))

## [0.8.1](https://github.com/Arenukvern/oka/compare/v0.8.0...v0.8.1) (2026-10-18)


### Bug Fixes

* **cli:** align usage banner and doctor doc pointer with the product surface ([d2d5dc3](https://github.com/Arenukvern/oka/commit/d2d5dc34a9b40ecbb20990398dcc2bfb1cd099dd))
* drop extraneous final parameter modifiers in oka_dart_kernel tool scripts ([a973f87](https://github.com/Arenukvern/oka/commit/a973f870bd29555bd84315b880456f0953a05049))


### Documentation

* **evidence:** codemap ADR-0045 live loop first light — supervised worker lifecycle + receipt-backed lane projection; ignore derived .codemap/ ([5c4b052](https://github.com/Arenukvern/oka/commit/5c4b052ec36f1b04cad785d49728f4050e9bee5f))
* realign docs with the four-pillar product north star ([b615650](https://github.com/Arenukvern/oka/commit/b615650e9a576d15cdfcb4753c864632744cd8ad))

## [0.8.0](https://github.com/Arenukvern/oka/compare/v0.7.0...v0.8.0) (2026-10-17)


### Features

* **dev:** composable dev browser and watch inputs (ADR 0044) ([929bc02](https://github.com/Arenukvern/oka/commit/929bc026992dc203dc45126678cd18dbd6f6d24f))
* **oka_core:** failed deadline teardown receipts + process observation budget (ADR 0046) ([d95cf89](https://github.com/Arenukvern/oka/commit/d95cf892e2826be36ed96964e8d21a42cb2ba2af))
* **resource_composition:** ArtifactFresh readiness — artifact-vs-sources freshness ([fc0337f](https://github.com/Arenukvern/oka/commit/fc0337fcf96315a3e22ecd49fcac28740960e5d5))
* **supervisor:** codemap index worker supervision (ADR 0045) ([268eeb2](https://github.com/Arenukvern/oka/commit/268eeb2be415bf87f6c6f0fdd1956abc1b482cea))
* **tool:** native preview probes — native launch + window capture (Swift) ([45dd283](https://github.com/Arenukvern/oka/commit/45dd283fc9a6aa6e7eced5c781e90051c9285ff0))


### Bug Fixes

* Dart 3.13 — SDK floors ^3.13.0, drop extraneous final parameter modifiers ([3f06123](https://github.com/Arenukvern/oka/commit/3f0612310478c288cd8f9f7396538359746486e6))
* **dev:** align oka_dart_kernel workspace constraints with the 0.7.0 train ([d06ded0](https://github.com/Arenukvern/oka/commit/d06ded071d6726d956d1afa8005e867585093672))
* green local gates — analyzer infos and maintainer paths ([adc248a](https://github.com/Arenukvern/oka/commit/adc248a170ab50d1df7226bd1ed73baac0282a7c))
* widen universal_automation_interface to ^0.3.0 in oka_harness/oka_update ([d54d123](https://github.com/Arenukvern/oka/commit/d54d123ee750bda1bf2e9cb03422c491d441705c))


### Documentation

* **skills:** oka-maintenance 1.7.0 — pub.dev publishing runbook ([f857426](https://github.com/Arenukvern/oka/commit/f857426e5386e34a05afc798e43d275c8ddd56e1))

## 0.7.0

### Added

- **Declarative supervisor (ADR-0040/0041).** `oka_supervisor` package:
  crash-only `Supervisor.converge`, plan JSON (`SpecCodec`), advisory
  `MachineRegistry`, and `oka supervisor status|apply|check` CLI verbs.
- **Anchored interval triggers** for supervisor jobs (`IntervalTrigger.at`
  wall-clock anchors).
- **Artifact store (ADR-0043).** `oka_artifacts` with delta chains;
  `oka artifacts` CLI (`put` / `materialize` / `verify`).
- **Live watcher command lanes (ADR-0038)** and Dart-first lane authoring.
- **Dev-session lanes:** watch-on-save default, asset sync/evict, shader
  bundle reinit in the asset lane (ADR-0037 follow-ups).

### Fixed

- Atomic runner-session publish and torn-read tolerant poll (`oka dev`).
- CLI help points at `https://github.com/arenukvern/oka`.

### Documentation

- Supervisor, artifacts, and OSS onboarding guides; newcomer FAQ; release
  manifest gate in `check-contracts`.

## 0.6.0

### Added

- **Build provenance + verification ladder (ADR-0029).** Every release
  artifact now carries `oka-provenance.json` (engine variant + jar hash,
  AOT snapshot hash + build id, pub-resolution hashes, fingerprints) and is
  validated before packaging: snapshot↔engine pairing, engine variant vs
  build mode, provenance completeness — a wrong pairing is a red build, not
  a device hanging on the splash screen.
- `oka run verify`: the verification ladder as a project-declared target —
  provenance, pairing, install, device health, launch, Dart main (startup
  beacon), first frame, failure signatures — with typed verdicts including
  **inconclusive-device** so unhealthy hosts/devices never produce silent
  evidence. Composable: `VerifyTarget(rungs: [...], extraFailureSignatures:
  [...])`.
- `oka why <step>`: explains a step-cache entry — per-input digests
  recorded at cache time, which inputs changed, and which build-affecting
  sources are not covered by the fingerprint.
- `FlutterBuild.startupProbe`: compiles a generated beacon wrapper so the
  `dart-main` rung can prove `main()` ran without app surgery.
- Failure signatures are data (`launch_failure_signatures.dart`): cause,
  fix, and evidence per needle, shared by `oka run device` and the ladder.

## 0.5.0

### Fixed

- **Android release engine pairing (splash-hang regression):** release APKs
  could package the **debug JIT engine** when the mode-specific
  `flutter.jar` was missing from the Flutter SDK cache — the app booted to
  the splash screen and never ran Dart `main()`. Engine variants are now
  resolved per build mode, `flutter precache --android` runs automatically on
  a cache miss, and a still-missing jar fails the build instead of being
  silently substituted. See
  `docs/evidence/android-release-engine-pairing-2026-09-27.mdx`.

### Changed

- `EngineArtifacts.findFlutterJar` / `extractLibflutter` /
  `extractLibflutterForAbis` take a variant string (`''`, `'-profile'`,
  `'-release'`, via `engineVariantForMode`) instead of a `release` boolean;
  `engineArtifactDirForAbi` is now `engineArtifactDirForVariant`. Profile
  builds use the profile engine directory (previously conflated with
  release).
- `flutter-assemble` / `release-aot` step fingerprints include
  path-dependency Dart sources (pub-workspace layouts resolved from the
  workspace-root `package_config.json`) and `buildArgs` — edits in sibling
  checkouts and R8/assemble argument changes no longer serve stale artifacts.

## 0.4.0

### Added

- `r8_rules` (ADR-0010 `AndroidBuild.r8Rules`): inline, per-app R8/ProGuard
  rules applied after `proguard_files`. oka's default R8 rules are now
  vendor-neutral — dependency-vendor `-dontwarn` lines (Firebase encoders,
  …) are declared per app instead of hardcoded into the platform package.

### Fixed

- `android.proguard_files` now reach R8 (repeated `--pg-conf`); they were
  collected but never passed to the shrinker.

## [0.2.0]

### Added

- Composable cache diagnostics with detailed device, profile, session and
  registry records, `--kind` filtering, and structured observations in JSON.

- Global `oka cache` overview, `clean` preview/apply, bounded project discovery
  with `--scan`, saved cleanup plans, optional terminal confirmation, and a
  machine-readable `schema` with next-action argv arrays.

- `oka cache stats` reports storage by path/platform, including emulator and
  simulator data; `oka cache prune` previews scoped cleanup and applies it only
  with `--apply`. JSON output supports agent workflows.

### Fixed

- Cache size help accepts KB/GB and KiB/GiB suffixes; indexed-store GC handles
  absent stores and measures extracted artifact payloads.

- Use Dart for release and stewardship tooling, without a Python runtime dependency.
- Harden release PR automation against shell interpretation of PR metadata.
- Synchronize and publish the complete seven-package release train, including
  compatible internal dependency constraints.
- Correct contributor setup commands and add enforced real-build CI validation.

## [0.1.6] - 2026-07-29

### Added

- **Complete no-Gradle plugin packaging** (`PluginPackager`):
  - Compile plugin Java/Kotlin sources into the app DEX
  - Parse Gradle deps + Maven/AAR resolve with limited POM transitives
  - Generate per-plugin `BuildConfig`
  - CMake/NDK build for `jni` → `libdartjni.so`
  - Real non-empty `GeneratedPluginRegistrant` by default
- d8 classpath: runtime vs compile-only jars; version/KMP artifact dedupe

### Changed

- Default `oka build apk` packages all plugins (no empty soft-shell registrant)
- `--soft-plugins` hidden escape hatch only

## [0.1.5] - 2026-07-18

### Added

- `oka get android-sdk` / packaging SDK bootstrap under `~/.oka/android-sdk` (cmdline-tools + build-tools 35 + platforms 34–36)
- `oka clean --android-sdk` for oka-managed SDK cleanup
- `--soft-plugins` build flag: skip jni/unsupported hard-fail; soft packaging uses empty plugin registrant
- Prefer oka-managed SDK root / `OKA_ANDROID_SDK` in locator

### Fixed

- Embedding classes extracted for d8 (avoid natives-in-jar)
- Platform jar fallback when compileSdk platform missing
- Metadata-only AndroidX AARs no longer abort dependency resolve

## [0.1.4] - 2026-07-18

### Added

- **No-Gradle Flutter APK pipeline (default `oka build apk`)**
  - `flutter assemble` orchestration (debug/profile/release targets)
  - Host codegen: `MainActivity` + `GeneratedPluginRegistrant`
  - APK layout staging/validation (`classes.dex`, `assets/flutter_assets/**`, `lib/<abi>/libflutter.so`)
  - Engine `libflutter.so` extraction from Flutter SDK `flutter.jar`
  - Minimal AndroidX + AAR `classes.jar` dependency cache (`DependencyCache`)
  - Plugin discovery from `.flutter-plugins-dependencies` with clear unsupported failures
  - Release multi-ABI + `libapp.so` packaging paths
  - Phase checklist: `docs/PHASE_CHECKLIST.mdx`
  - Unit tests under `test/` for all phases

### Changed

- Default build no longer uses cargo-apk hybrid or `flutter build apk` (Gradle) fallback
- `rust_wrapper` demoted; Cargo.toml valid and unused by default
- `--flutter` is a no-op alias; use `--native-android` for legacy non-Flutter pipeline

## [0.1.0] - 2025-01-10

### Added

- **Phase 1: Foundation & AI Infrastructure**

  - Project structure with CLI support
  - Extension type models for configuration (OkaConfig, AndroidConfig, Dependency, etc.)
  - AI agent integration with Apple Foundation Models and Gemini fallback
  - Prompt templates for Gradle conversion and manifest merging
  - Configuration caching system

- **Phase 2: Core Build Pipeline**

  - Android SDK tool locator (aapt2, d8, r8, kotlinc, javac, etc.)
  - APK builder with resource compilation, Kotlin/Java compilation, DEX conversion
  - APK packaging and signing with debug keystore
  - Basic incremental build support

- **CLI Commands**

  - `oka init` - Initialize oka.yaml from Gradle or create default config
  - `oka build apk` - Build debug or release APK
  - `oka doctor` - Check system requirements and configuration
  - `oka clean` - Clean build caches
  - `oka dev` - Stub for development mode (planned)

- **Documentation**
  - README with quick start guide
  - Architecture overview
  - Extension type model patterns
  - Configuration examples

### Known Limitations

- Dev mode (hot reload) not yet implemented
- AAR dependency processing not implemented
- Plugin discovery not implemented
- Manifest merging needs testing
- No AAB (Android App Bundle) support yet

### Next Steps

- Complete Phase 3: Dependency Resolution
- Complete Phase 4: Plugin Integration
- Complete Phase 5: Hot Reload
- Create example app with monetization + crashlytics
- Integration testing
