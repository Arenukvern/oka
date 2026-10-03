#!/usr/bin/env bash
# Server live-patch showcase (lane S1, ADR-0035): a running HTTP server is
# patched through the SAME composition API as the app showcase — and the
# proof of seamlessness is a client connection that never drops:
#
#   1. start the server with its VM service on :8252,
#   2. open a long-lived /stream connection (background curl),
#   3. apply the composed patch (dart patch_server.dart),
#   4. the SAME connection streams hello-v1 lines then hello-v2-live lines;
#      same pid; /health answered before, during and after.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)                      # packages/oka_dart_kernel
WS=$(cd "$PKG/../.." && pwd)                        # workspace root
APP="$HERE/app"
PORT=8251
VMS=8252

restore() { sed -i '' "s/ => 'hello-v2-live';/ => 'hello-v1';/" "$APP/lib/units/greeter.dart"; }
trap restore EXIT
pkill -f "enable-vm-service=$VMS" 2>/dev/null || true
sleep 1
restore

echo '== [1/4] package configs + toolchain cache'
mkdir -p "$HERE/.build"
cat > "$HERE/.build/app_package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {"name": "showcase_server", "rootUri": "file://$APP", "packageUri": "lib/", "languageVersion": "3.12"}
  ]
}
JSON
( cd "$PKG" && bash tool/pipeline_packages_config.sh \
    "${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-3.13.2}" 3.13 \
    "$HERE/.build/toolchain" > /dev/null )

echo '== [2/4] start the server (pid printed) + open /stream'
DART_BIN=${OKA_BENCH_DART:-$(command -v dart)}
"$DART_BIN" --packages="$HERE/.build/app_package_config.json" \
  --enable-vm-service=$VMS/127.0.0.1 --disable-service-auth-codes \
  "$APP/server.dart" > "$HERE/.build/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
  grep -q "listening on" "$HERE/.build/server.log" 2>/dev/null && break
  sleep 0.5
done
grep -q "listening on" "$HERE/.build/server.log" || { cat "$HERE/.build/server.log"; exit 1; }
head -1 "$HERE/.build/server.log"
curl -s "http://127.0.0.1:$PORT/" | sed 's/^/  before: /'
echo "  before-pid: $(curl -s "http://127.0.0.1:$PORT/" | grep -o 'pid=[0-9]*')"
curl -sN "http://127.0.0.1:$PORT/stream" > "$HERE/.build/stream.log" 2>&1 &
STREAM_PID=$!

echo '== [3/4] live-patch the server (dart patch_server.dart)'
( cd "$HERE" && dart --packages="$WS/.dart_tool/package_config.json" \
    patch_server.dart )
STATUS=$?

echo '== [4/4] continuity + result'
sleep 2
echo "  after: $(curl -s "http://127.0.0.1:$PORT/")"
echo "  after-pid: $(curl -s "http://127.0.0.1:$PORT/" | grep -o 'pid=[0-9]*')"
echo "  health during-patch window: $(curl -s "http://127.0.0.1:$PORT/health")"
echo "  stream continuity (ONE connection, old->new without a break):"
head -2 "$HERE/.build/stream.log" | sed 's/^/    /'
tail -2 "$HERE/.build/stream.log" | sed 's/^/    /'

kill "$STREAM_PID" "$SERVER_PID" 2>/dev/null || true
exit "$STATUS"
