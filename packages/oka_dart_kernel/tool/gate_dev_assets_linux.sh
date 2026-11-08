#!/usr/bin/env bash
# L0: dev-session asset + delta lanes on Linux desktop (example app).
#
# Usage: tool/gate_dev_assets_linux.sh
# Env: FLUTTER_BIN, OKA_LINUX_DEV_GATE_USE_XVFB=1
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_dev_assets_linux"
WS=$(cd "$HERE/../.." && pwd)
APP="$WS/example"
. "$HERE/tool/gate_lib.sh"
export FLUTTER_BIN=${FLUTTER_BIN:-$(command -v flutter)}
FAILED=0
ASSET="$APP/assets/hello.txt"
LEAF="$APP/lib/units/feature.dart"
ORIGINAL_ASSET="$(cat "$ASSET"; echo)"
ORIGINAL_LEAF="$(cat "$LEAF"; echo)"

if [ -z "$FLUTTER_BIN" ] || ! command -v "$FLUTTER_BIN" >/dev/null; then
  echo 'gate: FLUTTER_BIN/flutter not found' >&2
  exit 1
fi

restore() {
  printf '%s' "$ORIGINAL_ASSET" > "$ASSET"
  printf '%s' "$ORIGINAL_LEAF" > "$LEAF"
}
trap restore EXIT
restore

pkill_pattern "build/linux.*/bundle/example"
sleep 1
rm -rf "$OUT"; mkdir -p "$OUT"

NEW_CONTENT="asset-sync-gate-linux-$(date +%s)"
NEW_BYTES=$(printf '%s' "$NEW_CONTENT" | wc -c | tr -d ' ')
NEW_SUM=$(printf '%s' "$NEW_CONTENT" | od -An -tu1 | tr -s ' ' '\n' | grep -v '^$' | awk '{s+=$1} END {print s}')
FPRINT=$((NEW_BYTES * 1000003 + NEW_SUM))

PREFIX=""
if [ "${OKA_LINUX_DEV_GATE_USE_XVFB:-}" = "1" ]; then
  PREFIX="xvfb-run -a"
fi

echo "== [1/5] boot example under oka run dev --platform linux"
FIFO="$OUT/session.in"
mkfifo "$FIFO"
( cd "$WS" && $PREFIX dart --packages="$WS/.dart_tool/package_config.json" \
    "$WS/packages/oka/bin/oka.dart" run dev \
    --project "$APP" --platform linux --json --no-watch \
    < "$FIFO" > "$OUT/session.log" 2>&1 ) &
SESSION=$!
exec 3> "$FIFO"
wait_for "$OUT/session.log" 'dev: ready' 360 'dev session (linux)' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }

echo "== [2/5] r <leaf dart>: delta lane"
perl -pi -e "s/feature-v1/feature-v2-live/" "$LEAF"
grep -q 'feature-v2-live' "$LEAF" || { echo 'FAIL: dart edit'; FAILED=1; }
echo "r lib/units/feature.dart" >&3
wait_for "$OUT/session.log" 'reload 1: OK' 120 'delta reload' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }
grep -q '"reassemble": "ok"' "$OUT/session.log" \
  || { echo 'FAIL: reassemble missing'; FAILED=1; }

echo "== [3/5] r <asset>: sync lane"
printf '%s' "$NEW_CONTENT" > "$ASSET"
echo "r assets/hello.txt" >&3
wait_for "$OUT/session.log" 'assets 2:' 60 'asset sync' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }
grep -q 'assets 2: OK' "$OUT/session.log" \
  || { echo 'FAIL: asset sync not OK'; FAILED=1; }
grep -q '"evict": "ok"' "$OUT/session.log" \
  || { echo 'FAIL: ext.flutter.evict'; FAILED=1; }

echo "== [4/5] R: engine picks synced bytes"
echo 'R' >&3
wait_for "$OUT/session.log" 'restart: OK' 180 'hot restart' 5 \
  || { FAILED=1; exec 3>&-; kill "$SESSION" 2>/dev/null; restore; exit 1; }

echo "== [5/5] verify fingerprint via VM"
VMURI=$(grep -oE "VM service at http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_%-]+=" \
  "$OUT/session.log" | tail -1 | sed 's/^VM service at //')
[ -n "$VMURI" ] || { echo 'FAIL: no VM uri'; FAILED=1; }
cat > "$OUT/verify.json" <<EOF
{"revision": "gate", "unit": "gate", "patches": [],
 "targets": [{"kind": "vm", "id": "app", "ws": "${VMURI/http/ws}/ws",
              "http": "$VMURI", "devfs": "oka_gate_verify_linux",
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
  || { echo 'FAIL: fingerprint not verified'; FAILED=1; }

echo 'q' >&3
exec 3>&-
wait "$SESSION" 2>/dev/null
pkill_pattern "build/linux.*/bundle/example"
restore

if [ "$FAILED" -eq 0 ]; then
  echo 'gate: linux dev-session asset lane — ALL PASS'
else
  echo 'gate: linux dev-session asset lane — FAILED'
fi
exit $FAILED
