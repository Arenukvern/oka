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
oka init                # default: typed Dart config (tool/oka_pipeline.dart); --yaml for fast-settings
oka build apk --release # no Gradle, no daemon, no AGP
oka doctor              # verify the whole environment
```

Commands (`--help` on each), targets (`oka explain --targets`), and the full
documentation: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**.

This package is the CLI shell (parse-and-delegate only — ADR-0015): platform
pipelines, toolchain provisioning, and publish targets live in the sibling
sibling packages on the pub.dev train — see
[`tool/release/train_inventory.dart`](https://github.com/Arenukvern/oka/blob/main/tool/release/train_inventory.dart)
or `dart tool/release/train.dart list --publish`.

Requires **Dart ^3.14.0** and **Flutter 3.50** for Flutter workflows
(`tool/ci/toolchain_versions.yaml`).
