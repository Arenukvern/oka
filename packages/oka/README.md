# oka

The oka CLI — the publishable entry point of the
[oka build system](https://github.com/Arenukvern/oka): **one code for every
platform build**, starting with no-Gradle Flutter Android.

Install:

```bash
dart pub global activate oka
```

or via the repo installer:

```bash
curl -fsSL https://raw.githubusercontent.com/Arenukvern/oka/main/install.sh | bash
```

Then, in a Flutter project:

```bash
oka init                # scaffold the typed composition root
oka build apk --release # no Gradle, no daemon, no AGP
oka doctor              # verify the whole environment
```

Commands (`--help` on each), targets (`oka explain --targets`), and the full
documentation: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**.

This package is the CLI shell (parse-and-delegate only — ADR-0015): platform
pipelines, toolchain provisioning, and publish targets live in the sibling
packages (`oka_core`, `oka_android`, `oka_play`, `oka_huawei`, `oka_web`,
`oka_conformance`).
