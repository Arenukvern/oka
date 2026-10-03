#!/usr/bin/env bash
# ADR-0032 G2.5: multi-unit partitioning. Two declared units (tiny, greet)
# deferred-ized at the kernel level -> gen_snapshot emits 3 loading units
# (root + 2), each unit holding exactly its own library, app runs on Linux.
set -euo pipefail
HOST_HOME=${HOST_HOME:-$HOME} # the layout the baked package configs reference

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST_REPO=$(cd "$PKG_DIR/../.." && pwd)

docker run --rm -i \
  -v "$HOST_REPO:${HOST_HOME}/xs/oka" \
  -v "$HOME/xs/dart-sdks:${HOST_HOME}/xs/dart-sdks" \
  -v "$HOME/.pub-cache:${HOST_HOME}/.pub-cache" \
  -w ${HOST_HOME}/xs/oka/packages/oka_dart_kernel \
  dart:3.13.2 bash -s <<'SCRIPT'
set -euo pipefail
export DART_SDK_ROOT=/usr/lib/dart
SDK=$DART_SDK_ROOT
OUT=.gate_g1b
ENTRY=example/kernel_app/tool/gate_entry.dart
UNITS=(--unit=units/tiny.dart --unit=units/greet.dart)

mkdir -p example/kernel_app/.dart_tool
cat > example/kernel_app/.dart_tool/package_config.json <<'PKGEOF'
{
  "configVersion": 2,
  "packages": [
    {"name":"kernel_app","rootUri":"file://${HOST_HOME}/xs/oka/packages/oka_dart_kernel/example/kernel_app","packageUri":"lib/","languageVersion":"3.13"}
  ]
}
PKGEOF
export DART_PACKAGES_CONFIG=${HOST_HOME}/xs/oka/packages/oka_dart_kernel/example/kernel_app/.dart_tool/package_config.json

echo '=== [g25] pipeline (2 units)'
"$SDK/bin/dart" -Dsdk_hash=60a57cd42d \
  --packages="$OUT/pipeline_package_config.json" \
  tool/gate_pipeline.dart "${UNITS[@]}" "$ENTRY" "$OUT/g25.dill"

echo '=== [g25] gen_snapshot (ELF + manifest)'
"$SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/g25.so" \
  --loading_unit_manifest="$OUT/g25.manifest.json" \
  "$OUT/g25.dill"

echo '=== [g25] unit map'
"$SDK/bin/dart" tool/manifest_units.dart "$OUT/g25.manifest.json" | tee "$OUT/g25.units.txt"

echo '=== [g25] run'
"$SDK/bin/dartaotruntime" "$OUT/g25.so" > "$OUT/g25.run.log" 2>&1
cat "$OUT/g25.run.log"
grep -q 'GATE APP OK' "$OUT/g25.run.log" || { echo 'G2.5: FAIL (run output)'; exit 1; }

UNITS_N=$(grep -c '^[0-9]' "$OUT/g25.units.txt")
TINY_LINE=$(grep 'tiny.dart' "$OUT/g25.units.txt" | head -1 | cut -d' ' -f1)
GREET_LINE=$(grep 'greet.dart' "$OUT/g25.units.txt" | head -1 | cut -d' ' -f1)
ROOT_LINE=$(head -1 "$OUT/g25.units.txt" | cut -d' ' -f1)
echo "units=$UNITS_N root=$ROOT_LINE tiny_unit=$TINY_LINE greet_unit=$GREET_LINE"
if [ "$UNITS_N" -eq 3 ] && [ "$TINY_LINE" != "$GREET_LINE" ] \
   && [ "$TINY_LINE" != "$ROOT_LINE" ] && [ "$GREET_LINE" != "$ROOT_LINE" ]; then
  echo 'G2.5: PASS'
else
  echo 'G2.5: FAIL'
  exit 1
fi
SCRIPT
