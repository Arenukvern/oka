#!/usr/bin/env bash
# ADR-0032 G2 split proof: run the pipeline + gen_snapshot on Linux (ELF),
# where --loading_unit_manifest can emit multiple loading units. Asserts:
#   baseline (no hook)        -> 1 loading unit
#   --deferredize hook        -> >= 2 loading units, app runs (LoadLibrary works)
#
# Host paths are mounted into the container at identical absolute paths so the
# host-generated package_config (which uses absolute file:// URIs) resolves.
set -euo pipefail
HOST_HOME=${HOST_HOME:-$HOME} # the layout the baked package configs reference

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST_REPO=$(cd "$PKG_DIR/../.." && pwd)
SDK_HASH=$(git -C ~/xs/dart-sdks/sdk-3.13.2 rev-parse --short=10 HEAD 2>/dev/null || echo 60a57cd42d)

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

# kernel_app package_config (explicit; findPackages walk-up is unreliable
# inside the container's mounted tree). Mounted at identical absolute paths.
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

run() { # $1 = extra pipeline args, $2 = tag
  echo "=== [$2] pipeline"
  "$SDK/bin/dart" -Dsdk_hash=60a57cd42d \
    --packages="$OUT/pipeline_package_config.json" \
    tool/gate_pipeline.dart $1 "$ENTRY" "$OUT/$2.dill"
  echo "=== [$2] gen_snapshot (ELF + manifest)"
  "$SDK/bin/utils/gen_snapshot" \
    --snapshot-kind=app-aot-elf \
    --elf="$OUT/$2.so" \
    --loading_unit_manifest="$OUT/$2.manifest.json" \
    "$OUT/$2.dill"
  UNITS=$(grep -o '"path"' "$OUT/$2.manifest.json" | wc -l | tr -d ' ')
  echo "=== [$2] run ($UNITS loading units)"
  "$SDK/bin/dartaotruntime" "$OUT/$2.so"
  echo "$2: units=$UNITS"
}

run '' g2l_base
run --deferredize g2l

BASE=$(grep -o '"path"' "$OUT/g2l_base.manifest.json" | wc -l | tr -d ' ')
DEF=$(grep -o '"path"' "$OUT/g2l.manifest.json" | wc -l | tr -d ' ')
echo "baseline units: $BASE; deferredized units: $DEF"
if [ "$BASE" -eq 1 ] && [ "$DEF" -ge 2 ]; then
  echo 'G2 SPLIT PROOF: PASS'
else
  echo 'G2 SPLIT PROOF: FAIL'
  exit 1
fi
SCRIPT
