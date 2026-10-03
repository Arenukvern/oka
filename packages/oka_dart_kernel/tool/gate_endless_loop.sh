#!/usr/bin/env bash
# The endless dev loop on last_answer's real engine (ADR-0035): the driver
# boots with document state, then patch continue -> patch continue ->
# patch RESET -> patch RESET — all applied live over the VM service, with
# the boot-state probe holding after every step. Zero restarts.
#
# Usage: tool/gate_endless_loop.sh   (env: LIVE_APP_ROOT, OKA_SDK_CHECKOUT)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_endless"
APP_ROOT=${LIVE_APP_ROOT:-$HOME/xs/storage_problem/last_answer}
export LIVE_APP_ROOT="$APP_ROOT"
WS=$(cd "$HERE/../.." && pwd)
PORT=8244
. "$HERE/tool/gate_lib.sh"
mkdir -p "$OUT"

restore() {
  restore_marker "$APP_ROOT/packages/headless_core/lib/src/fractional_order.dart" \
    "const patchedAlphabet = 'acbdefghijklmnopqrstuvwxyz';" ""
  restore_marker "$APP_ROOT/packages/headless_core/lib/src/fractional_order.dart" \
    "patchedAlphabet.codeUnitAt(digit)" "_alphabet.codeUnitAt(digit)"
  restore_marker "$APP_ROOT/packages/headless_core/lib/src/doc_replica_store.dart" \
    "doc_replicas_live" "doc_replicas"
}
trap restore EXIT

pkill_pattern "oka_endless_driver.dart --serve"; sleep 1
restore

echo '== [1/3] start the endless driver (boot state) on :'"$PORT"
( cd "$APP_ROOT" && /opt/homebrew/bin/dart \
    --enable-vm-service=$PORT/127.0.0.1 --disable-service-auth-codes \
    tool/oka_endless_driver.dart --serve > "$OUT/driver.log" 2>&1 &
  echo $! > "$OUT/driver.pid" )
for _ in $(seq 1 40); do
  grep -q "endless] boot" "$OUT/driver.log" 2>/dev/null && break
  sleep 0.5
done
grep "endless] boot" "$OUT/driver.log" | head -1

echo '== [2/3] the loop: continue, continue, RESET, RESET (dart endless_loop.dart)'
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$HERE/tool/endless_loop.dart" ) 2>&1 | tee "$OUT/loop.log"
STATUS=${PIPESTATUS[0]}

echo '== [3/3] the driver, still alive after 4 patches + 2 resets:'
tail -1 "$OUT/driver.log"
kill "$(cat "$OUT/driver.pid")" 2>/dev/null
restore
grep -q "live patch OK" "$OUT/loop.log" && [ "$STATUS" = "0" ]
