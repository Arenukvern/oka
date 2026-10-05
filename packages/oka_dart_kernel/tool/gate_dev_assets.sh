#!/usr/bin/env bash
# Dev-session asset lane gate (ADR-0037 §6b, G-RUN): `oka run dev` boots
# the oka example app (declares assets/), then
#
#   r <leaf dart>  = the delta lane: probe flip + `reassemble: ok` in the
#                    receipt (the extension wire fix, G-RUN),
#   r <asset>      = the sync lane: bytes land in the engine's asset
#                    dir, `ext.flutter.evict` fires, and the receipt
#                    reports the post-evict probe honestly (on macOS the
#                    engine's asset cache serves the old mapping until
#                    the next engine cycle — flutter's own desktop asset
#                    hot reload has the same ceiling),
#   R              = the platform restart picks the synced bytes up,
#   verify         = a read-only probe pass proves the running app now
#                    serves the synced fingerprint.
#
# Usage: tool/gate_dev_assets.sh   (env: FLUTTER_BIN)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_dev_assets"
WS=$(cd "$HERE/../.." && pwd)
APP="$WS/example"
. "$HERE/tool/gate_lib.sh"
export FLUTTER_BIN=${FLUTTER_BIN:-$HOME/fvm/default/bin/flutter}
FAILED=0
ASSET="$APP/assets/hello.txt"
LEAF="$APP/lib/units/feature.dart"
ORIGINAL_ASSET="$(cat "$ASSET"; echo)"
ORIGINAL_LEAF="$(cat "$LEAF"; echo)"

restore() {
  printf '%s' "$ORIGINAL_ASSET" > "$ASSET"
  printf '%s' "$ORIGINAL_LEAF" > "$LEAF"
}
trap restore EXIT
restore

pkill_pattern "example.app/Contents/MacOS/example"
sleep 1
rm -rf "$OUT"; mkdir -p "$OUT"

# The synced fingerprint (length*1000003 + byte-sum), computed for the
# NEW content — the post-restart verify has a concrete expect.
NEW_CONTENT="asset-sync-gate-$(date +%s)"
NEW_BYTES=$(printf '%s' "$NEW_CONTENT" | wc -c | tr -d ' ')
NEW_SUM=$(printf '%s' "$NEW_CONTENT" | od -An -tu1 | tr -s ' ' '\n' | grep -v '^$' | awk '{s+=$1} END {print s}')
FPRINT=$((NEW_BYTES * 1000003 + NEW_SUM))

echo "== [1/5] boot the example app under oka run dev (macos)"
FIFO="$OUT/session.in"
mkfifo "$FIFO"
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$WS/packages/oka/bin/oka.dart" run dev \
    --project "$APP" --platform macos --json \
    < "$FIFO" > "$OUT/session.log" 2>&1 ) &
SESSION=$!
exec 3> "$FIFO"
wait_for "$OUT/session.log" 'dev: ready' 240 'dev session' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }

echo "== [2/5] r <leaf dart>: the delta lane (flip + reassemble)"
perl -pi -e "s/feature-v1/feature-v2-live/" "$LEAF"
grep -q 'feature-v2-live' "$LEAF" || { echo 'FAIL: dart edit'; FAILED=1; }
echo "r lib/units/feature.dart" >&3
wait_for "$OUT/session.log" 'reload 1: OK' 120 'delta reload' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }
grep -q '"reassemble": "ok"' "$OUT/session.log" \
  || { echo 'FAIL: reassemble never reached the app (extension wire?)'; FAILED=1; }

echo "== [3/5] r <asset>: the sync lane (bytes + evict, honest probe)"
printf '%s' "$NEW_CONTENT" > "$ASSET"
echo "r assets/hello.txt" >&3
wait_for "$OUT/session.log" 'assets 2:' 60 'asset sync' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }
grep -q 'assets 2: OK' "$OUT/session.log" \
  || { echo 'FAIL: asset sync receipt not OK'; FAILED=1; }
grep -q '"evict": "ok"' "$OUT/session.log" \
  || { echo 'FAIL: ext.flutter.evict did not fire'; FAILED=1; }

echo "== [4/5] R: the engine cycle picks the synced bytes up"
echo 'R' >&3
wait_for "$OUT/session.log" 'restart: OK' 180 'hot restart' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }

echo "== [5/5] verify: the app now serves the synced fingerprint"
VMURI=$(grep -oE "VM service at http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_%-]+=" \
  "$OUT/session.log" | tail -1 | sed 's/^VM service at //')
[ -n "$VMURI" ] || { echo 'FAIL: no VM uri'; FAILED=1; }
cat > "$OUT/verify.json" <<EOF
{"revision": "gate", "unit": "gate", "patches": [],
 "targets": [{"kind": "vm", "id": "app", "ws": "${VMURI/http/ws}/ws",
              "http": "$VMURI", "devfs": "oka_gate_verify",
              "applyVia": "reloadSources"}],
 "probes": [{"library": "main.dart",
             "expression": "helloAssetFingerprint()",
             "expect": "$FPRINT"}]}
EOF
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$HERE/tool/oka_live.dart" verify --spec "$OUT/verify.json" ) \
    > "$OUT/verify.log" 2>&1 \
  || { echo 'FAIL: verify refused'; tail -4 "$OUT/verify.log"; FAILED=1; }
grep -q 'live patch OK' "$OUT/verify.log" \
  || { echo 'FAIL: synced fingerprint not verified'; FAILED=1; }

echo 'q' >&3
exec 3>&-
wait "$SESSION" 2>/dev/null
restore

if [ "$FAILED" -eq 0 ]; then
  echo 'gate: dev-session asset lane (delta + sync + evict + engine cycle) — ALL PASS'
else
  echo 'gate: dev-session asset lane — FAILED'
fi
exit $FAILED
