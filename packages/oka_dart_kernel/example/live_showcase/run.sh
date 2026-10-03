#!/usr/bin/env bash
# Live-patch showcase: declare -> run -> patch -> apply -> verify, in ~30s.
#
#   1. builds the app's kernel dill with oka's pipeline (AOT exe when
#      available, JIT dart otherwise),
#   2. starts the app with a VM service,
#   3. runs the declarative live patch (example/live_showcase/live_patch.json)
#      through oka_update's LivePatchSession,
#   4. prints the receipt: the running app's feature() flipped
#      alpha-v1 -> alpha-v2-live and bootStamp HELD (no restart).
#
# Restores the source on exit; rerunnable. Usage: ./run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)                 # packages/oka_dart_kernel
APP="$HERE/app"
PORT=8242

restore() {
  sed -i '' "s/ => 'alpha-v2-live';/ => 'alpha-v1';/" "$APP/lib/units/feature.dart"
}
trap restore EXIT

echo '== [1/4] package config for the checkout kernel stack'
DART_BIN=${OKA_BENCH_DART:-$(command -v dart)}
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-3.13.2}
LANG_VERSION=3.13
PACKAGES=$( ( cd "$PKG" && bash tool/pipeline_packages_config.sh \
  "$CHECKOUT" "$LANG_VERSION" "$HERE/.build" ) | tail -1 )
SUMMARY=$(dirname "$(readlink -f "$DART_BIN")")/../lib/_internal/vm_platform_strong.dill
mkdir -p "$HERE/.build"
cat > "$HERE/.build/app_package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {"name": "showcase_app", "rootUri": "file://$APP", "packageUri": "lib/", "languageVersion": "3.12"}
  ]
}
JSON

pkill -f "enable-vm-service=$PORT" 2>/dev/null || true
sleep 1
echo '== [2/4] start the app with a VM service (ws://127.0.0.1:'"$PORT"'/ws)'
# The app MUST run under the same package config the delta is compiled
# with: the VM gives loaded libraries their package: URIs through it, and
# `_reloadKernel` matches the delta's libraries to the loaded ones by URI.
# A mismatch silently loads a stray copy and nothing changes.
"$DART_BIN" --packages="$HERE/.build/app_package_config.json" \
  --enable-vm-service=$PORT/127.0.0.1 --disable-service-auth-codes \
  "$APP/lib/main.dart" > "$HERE/.build/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 60); do
  grep -q "VM service is listening" "$HERE/.build/app.log" 2>/dev/null && break
  sleep 0.5
done
grep -q "VM service is listening" "$HERE/.build/app.log" || {
  echo "app did not start"; cat "$HERE/.build/app.log"; exit 1; }
grep "app:" "$HERE/.build/app.log" | head -1

echo '== [3/4] apply the composed live patch (dart patch.dart)'
( cd "$HERE" && dart --packages="/Users/antonio/xs/oka/.dart_tool/package_config.json" \
    patch.dart )
STATUS=$?

echo '== [4/4] the running app, patched live (no restart):'
grep "app \[tick" "$HERE/.build/app.log" | tail -2
kill "$APP_PID" 2>/dev/null || true
exit "$STATUS"
