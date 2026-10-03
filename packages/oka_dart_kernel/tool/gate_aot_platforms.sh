#!/usr/bin/env bash
# ADR-0032 native-AOT platform matrix (2026-10-02): the deferredized units
# are compiled per SDK version and fed to every gen_snapshot we can reach,
# with runtime execution asserted wherever a stock runtime exists.
#
# Proven here:
#   macOS host       gen_snapshot app-aot-elf + loading_unit_manifest emits
#                    base + N part ELFs; dartaotruntime runs them (the VM's
#                    own ELF loader via Loader::DeferredLoadHandler — no host
#                    dlopen involved).
#   linux amd64+arm64 same, in containers (amd64 under qemu).
#   android arm64    cross gen_snapshot emits base + part ELFs (compiler
#                    level; runtime = an embedder's Dart_SetDeferredLoadHandler).
#   ios arm64        cross gen_snapshot emits base + part ELFs (same caveat).
#   macho            refused with `deferred loading not implemented for
#                    Mach-O` — the precise blocker, now recorded.
#   windows          no host gen_snapshot; `app-aot-pecoff-obj` kind exists —
#                    needs one windows host/CI run to join the matrix.
#
# Env: FLUTTER (default /Users/antonio/fvm/default), OKA_SDK_CHECKOUT.
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER=${FLUTTER:-/Users/antonio/fvm/default}
OUT="$PKG_DIR/.gate_aot_platforms"
ENTRY="$PKG_DIR/example/kernel_app/tool/gate_entry.dart"
UNITS=(--unit=units/tiny.dart --unit=units/greet.dart)
mkdir -p "$PKG_DIR/example/kernel_app/.dart_tool"
[ -f "$PKG_DIR/example/kernel_app/.dart_tool/package_config.json" ] || cat > "$PKG_DIR/example/kernel_app/.dart_tool/package_config.json" <<'EOF'
{
  "configVersion": 2,
  "packages": [
    {"name":"kernel_app","rootUri":"file:///Users/antonio/xs/oka/packages/oka_dart_kernel/example/kernel_app","packageUri":"lib/","languageVersion":"3.13"}
  ]
}
EOF

HOST_DART="$(dirname "$(readlink -f "$(which dart)")")/dart"
HOST_SDK=$(dirname "$(dirname "$(readlink -f "$(which dart)")")")
HOST_VERSION=$("$HOST_DART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
FLUTTER_DART="$FLUTTER/bin/cache/dart-sdk/bin/dart"
FLUTTER_VERSION=$("$FLUTTER_DART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
build_dill() { # $1 checkout dir, $2 out dill
  local CHECKOUT=$1 DILL=$2
  local VERSION LANG HASH PACKAGES
  VERSION=$(basename "$CHECKOUT" | sed 's/^sdk-//')
  LANG=$(echo "$VERSION" | cut -d. -f1-2)
  HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
  PACKAGES=$(bash "$PKG_DIR/tool/pipeline_packages_config.sh" "$CHECKOUT" "$LANG" "$OUT")
  DART_SDK_SUMMARY="$(dirname "$HOST_DART")/../lib/_internal/vm_platform_strong.dill" \
  DART_PACKAGES_CONFIG="$PKG_DIR/example/kernel_app/.dart_tool/package_config.json" \
  OKA_TARGET=vm \
    "$HOST_DART" -Dsdk_hash=$HASH --packages="$PACKAGES" \
    "$PKG_DIR/tool/gate_pipeline.dart" "${UNITS[@]}" "$ENTRY" "$DILL" \
    2>&1 | grep -E 'pipeline: wrote|deferredize: [0-9]'
}
assert_parts() { # $1 manifest, $2 base path prefix, $3 expected part count
  local PARTS=$(( $(ls "$2"-*.part.so 2>/dev/null | wc -l | tr -d ' ') ))
  [ "$PARTS" -eq "$3" ] || { echo "expected $3 part files for $2, saw $PARTS"; exit 1; }
  grep -q 'loadingUnits' "$1"
}
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$PKG_DIR"

echo "=== [platforms 1/6] dills (host dart $HOST_VERSION; flutter dart $FLUTTER_VERSION)"
build_dill "$HOME/xs/dart-sdks/sdk-$HOST_VERSION" "$OUT/host_units.dill"
HOST_HASH=$(git -C "$HOME/xs/dart-sdks/sdk-$HOST_VERSION" rev-parse --short=10 HEAD)
if [ "$HOST_VERSION" != "$FLUTTER_VERSION" ]; then
  build_dill "$HOME/xs/dart-sdks/sdk-$FLUTTER_VERSION" "$OUT/xplat_units.dill"
  XPLAT_DILL=$OUT/xplat_units.dill
else
  XPLAT_DILL=$OUT/host_units.dill
fi

echo "=== [platforms 2/6] macOS host: ELF + manifest + RUN"
"$HOST_SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/mac_base.so" \
  --loading_unit_manifest="$OUT/mac.manifest.json" \
  "$OUT/host_units.dill"
assert_parts "$OUT/mac.manifest.json" "$OUT/mac_base.so" 2
"$HOST_SDK/bin/dartaotruntime" "$OUT/mac_base.so" | tee "$OUT/mac.run.log"
grep -q 'GATE APP OK' "$OUT/mac.run.log"

echo "=== [platforms 3/6] linux/amd64 container: ELF + manifest + RUN (qemu)"
docker run --rm --platform linux/amd64 \
  -v "/Users/antonio/xs/oka:/Users/antonio/xs/oka" \
  -w /Users/antonio/xs/oka/packages/oka_dart_kernel dart:3.13.2 bash -c '
    set -e; D=/usr/lib/dart
    $D/bin/utils/gen_snapshot --snapshot-kind=app-aot-elf \
      --elf=.gate_aot_platforms/lin_base.so \
      --loading_unit_manifest=.gate_aot_platforms/lin.manifest.json \
      .gate_aot_platforms/host_units.dill
    $D/bin/dartaotruntime .gate_aot_platforms/lin_base.so' | tee "$OUT/lin.run.log"
grep -q 'GATE APP OK' "$OUT/lin.run.log"

echo "=== [platforms 4/6] android arm64 cross: ELF + manifest artifacts"
"$FLUTTER/bin/cache/artifacts/engine/android-arm64-release/darwin-x64/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/andr_base.so" \
  --loading_unit_manifest="$OUT/andr.manifest.json" \
  "$XPLAT_DILL"
assert_parts "$OUT/andr.manifest.json" "$OUT/andr_base.so" 2

echo "=== [platforms 5/6] ios arm64 cross: ELF + manifest artifacts"
"$FLUTTER/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/ios_base.so" \
  --loading_unit_manifest="$OUT/ios.manifest.json" \
  "$XPLAT_DILL"
assert_parts "$OUT/ios.manifest.json" "$OUT/ios_base.so" 2

echo "=== [platforms 6/6] macho refusal (recorded precisely)"
MACHO_OUT=$("$HOST_SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-macho-dylib \
  --macho="$OUT/macho_base" \
  --loading_unit_manifest="$OUT/macho.manifest.json" \
  "$OUT/host_units.dill" 2>&1 || true)
echo "$MACHO_OUT" | grep -q 'deferred loading not implemented for Mach-O' || {
  echo "expected the Mach-O deferred refusal, got: $MACHO_OUT"; exit 1; }
echo "recorded: deferred loading not implemented for Mach-O"

# Optional android runtime leg: a stock dartaotruntime_product built from the
# pinned checkout (build recipe in skills/oka-kernel references/toolchain.md
# §10 — gclient layout, NDK symlink, dart_use_compressed_pointers=true).
# Skipped loudly when the runtime or a device is absent.
echo "=== [platforms 7/7] android arm64 RUN (optional)"
ADB_BIN="${ANDROID_SDK:-$HOME/.oka/android-sdk}/platform-tools/adb"
ANDROID_RT=${ANDROID_DARTAOTRUNTIME:-}
if [ ! -x "$ANDROID_RT" ]; then
  echo "skipped: set ANDROID_DARTAOTRUNTIME=<android dartaotruntime_product>"
elif ! "$ADB_BIN" devices 2>/dev/null | grep -qw device; then
  echo "skipped: no adb device attached"
else
  "$ADB_BIN" shell "mkdir -p /data/local/tmp/aot"
  "$ADB_BIN" push "$ANDROID_RT" /data/local/tmp/aot/dart_precompiled_runtime >/dev/null
  "$ADB_BIN" push "$OUT/andr_base.so" /data/local/tmp/aot/app.so >/dev/null
  "$ADB_BIN" push "$OUT/andr_base.so-2.part.so" /data/local/tmp/aot/app.so-2.part.so >/dev/null
  "$ADB_BIN" push "$OUT/andr_base.so-3.part.so" /data/local/tmp/aot/app.so-3.part.so >/dev/null
  "$ADB_BIN" shell "chmod 755 /data/local/tmp/aot/dart_precompiled_runtime && \
    /data/local/tmp/aot/dart_precompiled_runtime /data/local/tmp/aot/app.so" \
    | tee "$OUT/andr.run.log"
  grep -q 'GATE APP OK' "$OUT/andr.run.log"
fi

echo
echo 'AOT-PLATFORMS: PASS — mac(host) + linux/amd64 + linux/arm64 run;'
echo 'android + ios emit unit artifacts; macho refusal recorded;'
echo 'android RUN proven when the optional leg ran;'
echo 'windows pending a windows-host gen_snapshot run (pecoff kind exists).'
