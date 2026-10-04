# 04 — Stores & accounts: one app, many owners

The ladder's flagship. One codebase → **two Play accounts** (your studio +
a white-label client), **Huawei AppGallery** (GMS-free build), and
**RuStore** readiness — all as typed values in one file.

Companion guide (credential files, console setup, caveats):
[Accounts & stores](../../docs/guides/accounts_and_stores.mdx).

## The three moves

1. **Brands** — a `_brand()` helper builds an `AndroidPipeline` per brand
   (own application id, name, icon, keystore); `--flavor acme|client` picks
   one. It's a Dart program, not a DSL.
2. **Upload targets** — one `PlayPublishTarget` per account, each with its
   own `targetName`, `packageName`, and service-account path. Huawei/RuStore
   alongside.
3. **Dry-run first** — every target rehearses with zero HTTP and zero
   credentials. Flip `dryRun: false` only when ready.

## Run it

```bash
flutter pub get
flutter create . --platforms android    # one-time scaffold

# Build each brand (separate apps: different package id + icon)
oka explain                             # plan for the default brand (acme)
oka build apk --release --flavor acme
oka build apk --release --flavor client

# Rehearse every store (no credentials needed, nothing uploads)
oka explain --targets
oka run publish-play-acme
oka run publish-play-client
oka run publish-huawei
oka run publish-rustore
```

## Credentials (when you flip `dryRun: false`)

File paths, never values — per target: typed config path →
`OKA_PLAY_SERVICE_ACCOUNT_JSON`-style env var →
`~/.oka/credentials/<store>/`. Suggested layout (gitignore `keys/`):

```
keys/
  play-acme.json        # Play service account — your account
  play-client.json      # Play service account — client's account
  agc-acme.json         # AppGallery API client credential
```

Console setup (service accounts, grants, app ids): the
[publishing guide](../../docs/guides/publishing.mdx).

## Caveats (read once)

- Each brand is a **separate app** to every store — each needs its own
  console listing, and `versionCode` must increase per listing.
- Build outputs overwrite per invocation (`.oka_cache/build/<mode>/`) —
  build one brand at a time, or copy the artifact between builds.
- Signing: each brand gets its own keystore via env vars; one release key
  per listing, **stable across releases** (a re-signed app is a different
  app). Keystores are commented out below until you create them.

## Next

- [05 web stores](../05_web_stores) — same idea for web
- [06 live patch](../06_live_patch) — ship fixes without a store at all
