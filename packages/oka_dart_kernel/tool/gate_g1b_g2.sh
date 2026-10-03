#!/usr/bin/env bash
# ADR-0032 G1b + G2: runCompiler-shaped pipeline with a transform hook.
#
#   G1b: no-op hook -> gen_snapshot accepts the pipeline output -> runs.
#   G2:  --deferredize hook (DeferredFlag + await LoadLibrary, kernel-level,
#        no source changes) -> gen_snapshot splits loading units -> runs.
#
# Package config maps kernel/vm/front_end (+ deps) to the pinned SDK checkout.
# Env: OKA_SDK_CHECKOUT (default ~/xs/dart-sdks/sdk-<dart version>).
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR="$PKG_DIR/example/kernel_app"
SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
export DART_SDK_ROOT="$SDK"
DART_VERSION=$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$DART_VERSION}
OUT="$PKG_DIR/.gate_g1b"
# The release tag's short commit hash; kernel's expectedSdkHash is a
# compile-time -Dsdk_hash constant and the C++ backends gate on it.
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
ENTRY="$APP_DIR/tool/gate_entry.dart"
mkdir -p "$OUT"

echo "=== [1/5] dart $DART_VERSION; checkout: $CHECKOUT; sdk_hash: $SDK_HASH"
[ -f "$CHECKOUT/pkg/kernel/lib/kernel.dart" ] || { echo 'checkout missing'; exit 1; }

echo "=== [2/5] package_config (kernel, vm, front_end from checkout; deps pub-solved)"
# Collect declared deps of the checkout packages we consume.
deps=$(for p in kernel vm front_end; do
  awk '/^dependencies:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_]+:/{print $1}' \
    "$CHECKOUT/pkg/$p/pubspec.yaml" | tr -d ':'
done | sort -u)

# Classify: checkout-local packages vs third-party (pub-solved).
checkout_entries=""
pub_deps=""
for d in $deps; do
  if [ "$d" = "kernel" ] || [ "$d" = "vm" ] || [ "$d" = "front_end" ]; then continue; fi
  if [ -d "$CHECKOUT/pkg/$d/lib" ]; then
    checkout_entries+='    {"name":"'"$d"'","rootUri":"file://'"$CHECKOUT"'/pkg/'"$d"'","packageUri":"lib/","languageVersion":"3.13"},'$'\n'
  else
    pub_deps+="$d "
  fi
done

# Let pub solve a mutually consistent third-party set in a shim package.
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

# Merge: solved pub entries (minus the shim itself) + checkout packages.
python3 - "$OUT/depshim/.dart_tool/package_config.json" "$CHECKOUT" "$PKG_DIR" "$OUT/pipeline_package_config.json" "$checkout_entries" <<'EOF'
import json, sys
shim_cfg, checkout, pkg_dir, out_path, checkout_entries = sys.argv[1:6]
shim = json.load(open(shim_cfg))
entries = [e for e in shim["packages"] if e["name"] != "depshim"]
entries += [
    {"name": n, "rootUri": f"file://{checkout}/pkg/{n}", "packageUri": "lib/", "languageVersion": "3.13"}
    for n in ("kernel", "vm", "front_end")
]
for line in filter(None, checkout_entries.split("\n")):
    entries.append(json.loads(line.rstrip(",")))
entries.append({"name": "oka_dart_kernel", "rootUri": f"file://{pkg_dir}", "packageUri": "lib/", "languageVersion": "3.13"})
json.dump({"configVersion": 2, "packages": entries}, open(out_path, "w"), indent=1)
EOF

# kernel_app package_config (no pubspec: nested ones break workspace resolution)
mkdir -p "$APP_DIR/.dart_tool"
cat > "$APP_DIR/.dart_tool/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {"name":"kernel_app","rootUri":"file://$APP_DIR","packageUri":"lib/","languageVersion":"3.13"}
  ]
}
EOF
export DART_PACKAGES_CONFIG="$APP_DIR/.dart_tool/package_config.json"

run_gate() { # $1 = extra tool args, $2 = tag
  echo "=== [3/5][$2] pipeline"
  "$SDK/bin/dart" -Dsdk_hash="$SDK_HASH" \
    --packages="$OUT/pipeline_package_config.json" \
    "$PKG_DIR/tool/gate_pipeline.dart" $1 "$ENTRY" "$OUT/$2.dill"

  echo "=== [4/5][$2] gen_snapshot"
  # NOTE: --loading_unit_manifest triggers the multi-unit deferred path,
  # which is ELF-only ("deferred loading not implemented for Mach-O") — on
  # macOS we prove acceptance+execution (units merged); the split proof runs
  # in the Linux container (tool/gate_g2_linux.sh).
  local MANIFEST_FLAGS=()
  if [ "$(uname -s)" = "Linux" ]; then
    MANIFEST_FLAGS=(--loading_unit_manifest="$OUT/$2.manifest.json")
  fi
  "$SDK/bin/utils/gen_snapshot" \
    --snapshot-kind=app-aot-macho-dylib \
    --macho="$OUT/$2.aot" \
    "${MANIFEST_FLAGS[@]+"${MANIFEST_FLAGS[@]}"}" \
    "$OUT/$2.dill"

  echo "=== [5/5][$2] run"
  RUN_OUT=$("$SDK/bin/dartaotruntime" "$OUT/$2.aot")
  echo "$RUN_OUT"
  echo "$RUN_OUT" | grep -q 'GATE APP OK' || { echo "GATE $2: FAIL"; exit 1; }
}

echo '################ G1b: no-op hook ################'
run_gate '' g1b
echo 'G1b: PASS (gen_snapshot accepted pipeline output, app runs)'

echo '################ G2: deferredize hook ################'
run_gate '--deferredize' g2
echo 'G2 (macOS acceptance): PASS — deferredize dill accepted and runs.'
echo 'G2 split proof (loading units >= 2): run tool/gate_g2_linux.sh.'
