#!/usr/bin/env bash
# ADR-0032 G2.5-real: the kernel transform pointed at a REAL multi-unit app
# (~/xs/storage_problem/last_answer, overridable with APP_ROOT).
#
# Declared units are two real headless_core modules with a genuine dependency
# chain — doc_replica.dart (unit A) and doc_replica_store.dart (unit B,
# imports A) — so the partition must order A before B. Shared libraries the
# barrel exports or both units import (document_node,
# universal_storage_convergence) must stay in the root unit: the VM assigns
# loading units by dominator, so a library with importers in two units is
# root's. The pipeline compiles the app's real workspace package_config,
# gen_snapshot emits the loading-unit manifest, and the AOT app runs.
#
# Env: APP_ROOT (default ~/xs/storage_problem/last_answer),
#      OKA_SDK_CHECKOUT (default ~/xs/dart-sdks/sdk-3.13.2).
set -euo pipefail
HOST_HOME=${HOST_HOME:-$HOME} # the layout the baked package configs reference

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST_REPO=$(cd "$PKG_DIR/../.." && pwd)
APP_ROOT=${APP_ROOT:-$HOME/xs/storage_problem/last_answer}
PROBLEM_ROOT=$(dirname "$APP_ROOT")
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-3.13.2}
[ -d "$APP_ROOT" ] || { echo "APP_ROOT missing: $APP_ROOT"; exit 1; }
[ -f "$APP_ROOT/.dart_tool/package_config.json" ] || {
  echo 'app has no .dart_tool/package_config.json (run pub get first)'; exit 1; }

docker run --rm -i \
  -e HOME=${HOST_HOME} \
  -v "$HOST_REPO:${HOST_HOME}/xs/oka" \
  -v "$PROBLEM_ROOT:${HOST_HOME}/xs/storage_problem" \
  -v "$CHECKOUT:${HOST_HOME}/xs/dart-sdks/sdk-3.13.2" \
  -v "$HOME/.pub-cache:${HOST_HOME}/.pub-cache" \
  -w ${HOST_HOME}/xs/oka/packages/oka_dart_kernel \
  dart:3.13.2 bash -s <<'SCRIPT'
set -euo pipefail
export DART_SDK_ROOT=/usr/lib/dart
SDK=$DART_SDK_ROOT
OUT=.gate_real_app
APP=${HOST_HOME}/xs/storage_problem/last_answer
ENTRY=$APP/tool/oka_kernel_driver.dart
UNITS=(
  --unit=package:headless_core/src/doc_replica.dart
  --unit=package:headless_core/src/doc_replica_store.dart
)
mkdir -p "$OUT"

echo '=== [g25-real 1/5] pipeline package_config (kernel stack from checkout)'
deps=$(for p in kernel vm front_end; do
  awk '/^dependencies:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_]+:/{print $1}' \
    "${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/$p/pubspec.yaml" | tr -d ':'
done | sort -u)
pub_deps=""
checkout_entries=""
for d in $deps; do
  case "$d" in kernel|vm|front_end) continue ;; esac
  if [ -d "${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/$d/lib" ]; then
    checkout_entries+=$'\n  {"name": "'"$d"'", "rootUri": "file://${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/'"$d"'", "packageUri": "lib/", "languageVersion": "3.13"},'
  else
    pub_deps+="$d "
  fi
done
mkdir -p "$OUT/depshim"
{
  echo 'name: depshim'
  echo 'publish_to: none'
  echo 'environment:'
  echo '  sdk: ^3.13.0'
  echo 'dependencies:'
  for d in $pub_deps; do echo "  $d: any"; done
} > "$OUT/depshim/pubspec.yaml"
(cd "$OUT/depshim" && dart pub get >/dev/null 2>&1) || { echo 'shim pub get failed'; exit 1; }
cat > "$OUT/extra_entries.json" <<JSONEOF
[
  {"name": "kernel", "rootUri": "file://${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/kernel", "packageUri": "lib/", "languageVersion": "3.13"},
  {"name": "vm", "rootUri": "file://${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/vm", "packageUri": "lib/", "languageVersion": "3.13"},
  {"name": "front_end", "rootUri": "file://${HOST_HOME}/xs/dart-sdks/sdk-3.13.2/pkg/front_end", "packageUri": "lib/", "languageVersion": "3.13"},$checkout_entries
  {"name": "oka_dart_kernel", "rootUri": "file://${HOST_HOME}/xs/oka/packages/oka_dart_kernel", "packageUri": "lib/", "languageVersion": "3.13"}
]
JSONEOF
"$SDK/bin/dart" tool/merge_package_config.dart \
  "$OUT/depshim/.dart_tool/package_config.json" \
  "$OUT/pipeline_package_config.json" \
  "$OUT/extra_entries.json"

echo '=== [g25-real 2/5] pipeline (dependency-ordered partition, 2 real units)'
export DART_PACKAGES_CONFIG=$APP/.dart_tool/package_config.json
"$SDK/bin/dart" -Dsdk_hash=60a57cd42d \
  --packages="$OUT/pipeline_package_config.json" \
  tool/gate_pipeline.dart "${UNITS[@]}" "$ENTRY" "$OUT/real.dill" \
  | tee "$OUT/real.pipeline.log"

echo '=== [g25-real 3/5] gen_snapshot (ELF + loading-unit manifest)'
"$SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/real.so" \
  --loading_unit_manifest="$OUT/real.manifest.json" \
  "$OUT/real.dill"

echo '=== [g25-real 4/5] unit map'
"$SDK/bin/dart" tool/manifest_units.dart "$OUT/real.manifest.json" \
  | tee "$OUT/real.units.txt"

echo '=== [g25-real 5/5] run the real app'
"$SDK/bin/dartaotruntime" "$OUT/real.so" > "$OUT/real.run.log" 2>&1
cat "$OUT/real.run.log"
grep -q 'root: fractionalBetween' "$OUT/real.run.log" || { echo 'G2.5-real: FAIL (root label)'; exit 1; }
grep -q 'unitA(doc_replica)' "$OUT/real.run.log" || { echo 'G2.5-real: FAIL (unitA label)'; exit 1; }
grep -q 'unitB(doc_replica_store)' "$OUT/real.run.log" || { echo 'G2.5-real: FAIL (unitB label)'; exit 1; }

UNITS_N=$(grep -c '^[0-9]' "$OUT/real.units.txt")
ROOT_LINE=$(head -1 "$OUT/real.units.txt" | cut -d' ' -f1)
A_LINE=$(grep 'src/doc_replica.dart' "$OUT/real.units.txt" | head -1 | cut -d' ' -f1)
B_LINE=$(grep 'src/doc_replica_store.dart' "$OUT/real.units.txt" | head -1 | cut -d' ' -f1)
CONV_LINE=$(grep 'universal_storage_convergence' "$OUT/real.units.txt" | head -1 | cut -d' ' -f1)
NODE_LINE=$(grep 'src/document_node.dart' "$OUT/real.units.txt" | head -1 | cut -d' ' -f1)
echo "units=$UNITS_N root=$ROOT_LINE doc_replica=$A_LINE doc_replica_store=$B_LINE convergence=$CONV_LINE document_node=$NODE_LINE"
if [ "$UNITS_N" -eq 3 ] && [ -n "$A_LINE" ] && [ -n "$B_LINE" ] \
   && [ "$A_LINE" != "$ROOT_LINE" ] && [ "$B_LINE" != "$ROOT_LINE" ] \
   && [ "$A_LINE" != "$B_LINE" ] && [ "$A_LINE" -lt "$B_LINE" ] \
   && [ "$CONV_LINE" = "$ROOT_LINE" ] && [ "$NODE_LINE" = "$ROOT_LINE" ]; then
  echo 'G2.5-real: PASS — real app partitioned into root + 2 ordered units; shared libs stayed in root'
else
  echo 'G2.5-real: FAIL'
  exit 1
fi
SCRIPT
