#!/usr/bin/env bash
# ADR-0032 G2.5-real-B: the kernel transform pointed at the REAL Flutter app
# entry (last_answer lib/main.dart), compiled against the Flutter patched
# SDK through the checkout kernel stack, partitioned into real feature
# units, and fed to the engine's gen_snapshot (android arm64 cross from
# macOS) for a loading-unit manifest.
#
# Manifest-only gate: the android ELF runs on a device/emulator through
# oka's build harness — not here. Env:
#   APP_ROOT   (default ~/xs/storage_problem/last_answer)
#   FLUTTER    (default ${HOST_HOME}/fvm/default)
#   OKA_SDK_CHECKOUT (default ~/xs/dart-sdks/sdk-<flutter dart version>)
set -euo pipefail
HOST_HOME=${HOST_HOME:-$HOME} # the layout the baked package configs reference

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_ROOT=${APP_ROOT:-$HOME/xs/storage_problem/last_answer}
FLUTTER=${FLUTTER:-${HOST_HOME}/fvm/default}
FDART="$FLUTTER/bin/cache/dart-sdk/bin/dart"
FDART_VERSION=$("$FDART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LANG_VERSION=$(echo "$FDART_VERSION" | cut -d. -f1-2)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$FDART_VERSION}
PATCHED_SDK="$FLUTTER/bin/cache/artifacts/engine/common/flutter_patched_sdk"
GEN_SNAPSHOT="$FLUTTER/bin/cache/artifacts/engine/android-arm64-release/darwin-x64/gen_snapshot"
OUT="$PKG_DIR/.gate_real_flutter"
ENTRY="$APP_ROOT/lib/main.dart"
# --no-guards: manifest-only gate — the app's sync `void main()` cannot take
# inserted awaits (kernel-level async is not CFE-lowered). A run leg needs an
# async main or the body-wrap rewrite (recorded follow-up).
UNITS=(
  --no-guards
  --unit=package:lastanswer/idea/
  --unit=package:lastanswer/note/
)
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)

for f in "$ENTRY" "$PATCHED_SDK/platform_strong.dill" "$GEN_SNAPSHOT" \
         "$CHECKOUT/pkg/kernel/lib/kernel.dart" \
         "$APP_ROOT/.dart_tool/package_config.json"; do
  [ -e "$f" ] || { echo "missing: $f"; exit 1; }
done
mkdir -p "$OUT"

echo "=== [g25-B 1/4] pipeline package_config (checkout $FDART_VERSION, sdk_hash $SDK_HASH)"
deps=$(for p in kernel vm front_end; do
  awk '/^dependencies:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_]+:/{print $1}' \
    "$CHECKOUT/pkg/$p/pubspec.yaml" | tr -d ':'
done | sort -u)
pub_deps=""
checkout_entries=""
for d in $deps; do
  case "$d" in kernel|vm|front_end) continue ;; esac
  if [ -d "$CHECKOUT/pkg/$d/lib" ]; then
    checkout_entries+=$'\n  {"name": "'"$d"'", "rootUri": "file://'"$CHECKOUT"'/pkg/'"$d"'", "packageUri": "lib/", "languageVersion": "'"$LANG_VERSION"'"},'
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
  {"name": "kernel", "rootUri": "file://$CHECKOUT/pkg/kernel", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},
  {"name": "vm", "rootUri": "file://$CHECKOUT/pkg/vm", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},
  {"name": "front_end", "rootUri": "file://$CHECKOUT/pkg/front_end", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},$checkout_entries
  {"name": "oka_dart_kernel", "rootUri": "file://$PKG_DIR", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"}
]
JSONEOF
"$FDART" tool/merge_package_config.dart \
  "$OUT/depshim/.dart_tool/package_config.json" \
  "$OUT/pipeline_package_config.json" \
  "$OUT/extra_entries.json"

echo '=== [g25-B 2/4] pipeline: real Flutter entry + patched SDK + 2 feature units'
export DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json"
export DART_SDK_SUMMARY="$PATCHED_SDK/platform_strong.dill"
export OKA_TARGET_OS=android
export OKA_TARGET=flutter
"$FDART" -Dsdk_hash="$SDK_HASH" \
  --packages="$OUT/pipeline_package_config.json" \
  tool/gate_pipeline.dart "${UNITS[@]}" "$ENTRY" "$OUT/flutter_app.dill" \
  2>&1 | tee "$OUT/flutter.pipeline.log" | grep -E 'pipeline:|deferredize: unit|deferredize: [0-9]'

echo '=== [g25-B 3/4] gen_snapshot (android arm64 ELF + loading-unit manifest)'
"$GEN_SNAPSHOT" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/flutter_app.so" \
  --loading_unit_manifest="$OUT/flutter_app.manifest.json" \
  "$OUT/flutter_app.dill"

echo '=== [g25-B 4/4] unit map + assertions'
"$FDART" tool/manifest_units.dart "$OUT/flutter_app.manifest.json" \
  | tee "$OUT/flutter_app.units.txt"

# Manifest semantics are dominator-based: a feature with ONE outside seam
# (note: only project_view imports it) stays a single coherent unit; a
# feature with several outside seams (idea: home/project_view/settings all
# import deep files) fragments into one unit per seam, and seam-shared
# blocs stay in root. Assert the real shapes.
UNITS_N=$(grep -c '^[0-9]' "$OUT/flutter_app.units.txt")
NOTE_ROOT=$(sed -n 1p "$OUT/flutter_app.units.txt" | tr ',' '\n' | grep -c 'package:lastanswer/note/' || true)
NOTE_UNIT=$(sed -n "2,\$p" "$OUT/flutter_app.units.txt" | tr ',' '\n' | grep -c 'package:lastanswer/note/' || true)
IDEA_NONROOT_UNITS=$([ "$UNITS_N" -ge 2 ] && sed -n "2,\$p" "$OUT/flutter_app.units.txt" | grep -c 'package:lastanswer/idea/' || true)
CREATE_LINE=$(grep 'create_idea_screen' "$OUT/flutter_app.units.txt" | head -1 | cut -d' ' -f1)
VIEW_LINE=$(grep 'idea/idea_view.dart' "$OUT/flutter_app.units.txt" | head -1 | cut -d' ' -f1)
echo "units=$UNITS_N note_root=$NOTE_ROOT note_in_units=$NOTE_UNIT idea_in_units=$IDEA_NONROOT_UNITS create_idea=$CREATE_LINE idea_view=$VIEW_LINE"
if [ "$UNITS_N" -ge 3 ] && [ "$NOTE_ROOT" -eq 0 ] && [ "$NOTE_UNIT" -gt 0 ] \
   && [ "$IDEA_NONROOT_UNITS" -gt 0 ] && [ "$CREATE_LINE" != "$VIEW_LINE" ]; then
  echo 'G2.5-real-B: PASS — real Flutter entry (4087 libs) split into real loading units; single-seam feature (note) coherent, multi-seam feature (idea) per-seam units'
else
  echo 'G2.5-real-B: FAIL'
  exit 1
fi
