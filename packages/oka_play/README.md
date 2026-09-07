# oka_play

Google Play publish target for [oka](https://github.com/Arenukvern/oka)
(ADR-0014 P1): `PlayPublishTarget` composes the Play Publisher API upload
tail onto any oka Android AAB build.

```dart
Oka(
  pipelines: [AndroidPipeline(config: AndroidBuild(packageName: '...'))],
  targets: [
    PlayPublishTarget(), // dry-run plan, zero HTTP (the default)
    PlayPublishTarget(
      dryRun: false,
      packageName: 'dev.example.app',
      track: PlayTrack.internal,
      serviceAccountPath: 'credentials/play-sa.json', // path, never value
    ),
  ],
)
```

- **Credential:** service-account JSON by *path* (ADR-0014 three-tier
  model) — typed-config path → `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var
  (naming a path) → `~/.oka/credentials/play/service-account-json`.
- **Flow:** JWT (RS256, googleapis_auth) → OAuth token exchange → Edits API
  (create edit → upload AAB → assign track → commit). Default track:
  `internal`.
- **Dry-run:** the default; produces the publish plan (endpoint, track,
  artifact, metadata) and issues zero HTTP. Real uploads are explicit.
- **Conformance:** asserted with the shared suite in
  [oka_conformance](../oka_conformance).

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions).
