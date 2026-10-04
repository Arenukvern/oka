# 03 — Release builds: signing, R8, provenance, verification

From "runs on my phone" to "ship-ready artifact that proves it starts".

## What's new vs [01](../01_hello_app)

- **Release config**: `versionCode`/`versionName` bump, release signing via
  environment variables (secrets never live in the config file).
- **R8**: release builds run the real shrinker; `mapping.txt` lands next to
  the APK for Play deobfuscation.
- **Provenance**: every artifact carries `oka-provenance.json`; a wrong
  engine/snapshot pairing fails the build instead of hanging the device.
- **`oka run verify`**: a ladder that proves install → launch → Dart
  `main()` → first frame on a real device.

## Run it

```bash
# dev loop still works exactly like 02
oka build apk --debug && oka dev

# release, with your key
export OKA_STORE_PASS=...        # keystore password — env, not file
export OKA_KEY_PASS=...
oka build apk --release          # → .oka_cache/build/release/app-release.apk
                                 #    (+ r8/mapping.txt)

# store upload format
oka get bundletool               # one-time
oka build aab --release --verify-aab

# prove the release actually starts (ADR-0029)
oka run verify
```

## No keystore yet?

For local release testing oka falls back to the debug keystore **with a
loud warning** — stores will reject it. Create a real one when ready:

```bash
keytool -genkey -v -keystore keys/release.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias upload
```

Add `keys/` to `.gitignore`. Per-account and per-brand keystores:
[Accounts & stores guide](../../docs/guides/accounts_and_stores.mdx).

## Next

- [04 stores & accounts](../04_stores_accounts) — publish targets
