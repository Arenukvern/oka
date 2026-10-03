#!/usr/bin/env bash
# ADR-0032 Gate 1: round-trip a dill through pkg/kernel, gen_snapshot it, run it.
#
#   dill --(pkg/kernel load+serialize)--> dill --(gen_snapshot)--> ELF/macho
#   --(dartaotruntime)--> expect "GATE APP OK"
#
# The pkg/kernel sources come from a pinned dart-lang/sdk checkout (machine-
# local toolchain input; never committed, never a fork).
#
# Env: OKA_SDK_CHECKOUT (default ~/xs/dart-sdks/sdk-<dart version>)
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR="$PKG_DIR/example/kernel_app"
SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
DART_VERSION=$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$DART_VERSION}
OUT="$PKG_DIR/.gate1"
mkdir -p "$OUT"
case "$(uname -s)" in
  Darwin) HOST_TARGET_OS=macos ;;
  Linux) HOST_TARGET_OS=linux ;;
  *) HOST_TARGET_OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac

echo "=== [1/5] dart $DART_VERSION; checkout: $CHECKOUT"
if [ ! -d "$CHECKOUT/pkg/kernel" ]; then
  mkdir -p "$(dirname "$CHECKOUT")"
  echo "cloning dart-lang/sdk (shallow, tag $DART_VERSION) ..."
  git clone --depth 1 --branch "$DART_VERSION" \
    https://github.com/dart-lang/sdk.git "$CHECKOUT"
fi
[ -f "$CHECKOUT/pkg/kernel/lib/kernel.dart" ] || { echo 'pkg/kernel missing in checkout'; exit 1; }

echo "=== [2/5] dill via gen_kernel"
# kernel_app has no package deps; generate its package_config directly (a
# nested pubspec would break workspace resolution).
mkdir -p "$APP_DIR/.dart_tool"
cat > "$APP_DIR/.dart_tool/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {"name":"kernel_app","rootUri":"file://$APP_DIR","packageUri":"lib/","languageVersion":"3.13"}
  ]
}
EOF
"$SDK/bin/dartaotruntime" "$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot" \
  --platform="$SDK/lib/_internal/vm_platform_strong.dill" \
  --aot --packages="$APP_DIR/.dart_tool/package_config.json" \
  --target-os="$HOST_TARGET_OS" \
  -o "$OUT/program.dill" "$APP_DIR/tool/gate_entry.dart"

echo "=== [3/5] round-trip through pkg/kernel ($CHECKOUT/pkg/kernel)"
# Build a package_config mapping kernel, vm (+ their deps as resolvable) into
# the checkout. Third-party deps are satisfied from the pub cache.
deps=$(for p in kernel vm; do
  awk '/^dependencies:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_]+:/{print $1}' \
    "$CHECKOUT/pkg/$p/pubspec.yaml" | tr -d ':'
done | sort -u)
{
  echo '{'
  echo '  "configVersion": 2,'
  echo '  "packages": ['
  echo '    {"name":"kernel","rootUri":"file://'"$CHECKOUT"'/pkg/kernel","packageUri":"lib/","languageVersion":"3.13"},'
  echo '    {"name":"vm","rootUri":"file://'"$CHECKOUT"'/pkg/vm","packageUri":"lib/","languageVersion":"3.13"},'
  for d in $deps; do
    [ "$d" = "kernel" ] || [ "$d" = "vm" ] && continue
    # try checkout locations first, then newest pub-cache copy
    if [ -d "$CHECKOUT/pkg/$d/lib" ]; then
      loc="$CHECKOUT/pkg/$d"
    elif [ -d "$CHECKOUT/third_party/pkg/$d/lib" ]; then
      loc="$CHECKOUT/third_party/pkg/$d"
    else
      dart pub cache add "$d" >/dev/null 2>&1 || true
      loc=$(ls -d "$HOME/.pub-cache/hosted/pub.dev/$d-"* 2>/dev/null | sort -V | tail -1)
    fi
    if [ -n "$loc" ] && [ -d "$loc/lib" ]; then
      echo '    {"name":"'"$d"'","rootUri":"file://'"$loc"'","packageUri":"lib/","languageVersion":"3.13"},'
    fi
  done
  echo '    {"name":"oka_dart_kernel","rootUri":"file://'"$PKG_DIR"'","packageUri":"lib/","languageVersion":"3.13"}'
  echo '  ]'
  echo '}'
} > "$OUT/roundtrip_package_config.json"
# remove trailing comma before closing bracket (JSON hygiene)
perl -0pi -e 's/},\n  \]/}\n  ]/' "$OUT/roundtrip_package_config.json"

# Carry the input dill's SDK hash: kernel's expectedSdkHash is a compile-time
# -Dsdk_hash constant; the official gen_kernel bakes the release hash, and the
# C++ backends gate on it (placeholder 0000000000 breaks table-selector
# consumption in gen_snapshot).
SDK_HASH=$(python3 -c "print(open('$OUT/program.dill','rb').read(18)[8:18].decode('ascii'))")
echo "sdk hash: $SDK_HASH"

"$SDK/bin/dart" -Dsdk_hash="$SDK_HASH" \
  --packages="$OUT/roundtrip_package_config.json" \
  "$PKG_DIR/tool/kernel_roundtrip.dart" "$OUT/program.dill" "$OUT/program.rt.dill"

echo "=== [4/5] gen_snapshot on the round-tripped dill"
"$SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-macho-dylib \
  --macho="$OUT/gate.rt.aot" \
  "$OUT/program.rt.dill"

echo "=== [5/5] run"
RUN_OUT=$("$SDK/bin/dartaotruntime" "$OUT/gate.rt.aot")
echo "$RUN_OUT"
if echo "$RUN_OUT" | grep -q 'GATE APP OK'; then
  echo 'GATE1: PASS'
else
  echo 'GATE1: FAIL'
  exit 1
fi
