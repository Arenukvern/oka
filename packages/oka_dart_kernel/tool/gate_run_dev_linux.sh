#!/usr/bin/env bash
# L0: converged dev session on Linux desktop (example app).
# Reload + restart via `oka run dev --platform linux` (not raw flutter).
#
# Usage: tool/gate_run_dev_linux.sh
# Env: FLUTTER_BIN, WS (optional), OKA_LINUX_DEV_GATE_USE_XVFB=1
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WS=${WS:-$(cd "$HERE/../.." && pwd)}
OUT="$HERE/.gate_run_dev_linux"
APP_ROOT="$WS/example"
. "$HERE/tool/gate_lib.sh"
export FLUTTER_BIN=${FLUTTER_BIN:-$(command -v flutter)}
mkdir -p "$OUT"
FAILED=0

if [ -z "$FLUTTER_BIN" ] || ! command -v "$FLUTTER_BIN" >/dev/null; then
  echo 'gate: FLUTTER_BIN/flutter not found — install Flutter linux desktop' >&2
  exit 1
fi

UNIT_FILE="lib/units/feature.dart"
ORIGINAL="$(cat "$APP_ROOT/$UNIT_FILE")"
restore() { printf '%s' "$ORIGINAL" > "$APP_ROOT/$UNIT_FILE"; }
trap restore EXIT
restore

write_probes() {
  cat > "$OUT/probes-linux.json" <<'EOF'
[{"library": "units/feature.dart", "expression": "featureLabel()", "expect": "feature-v2-live"}]
EOF
}

edit_file() {
  perl -pi -e "s/feature-v1/feature-v2-live/" "$APP_ROOT/$UNIT_FILE"
  grep -q 'feature-v2-live' "$APP_ROOT/$UNIT_FILE"
}

run_leg() {
  local log="$OUT/linux.log"
  local fifo="$OUT/linux.in"
  write_probes
  restore
  rm -f "$fifo"; mkfifo "$fifo"

  local prefix=""
  if [ "${OKA_LINUX_DEV_GATE_USE_XVFB:-}" = "1" ]; then
    prefix="xvfb-run -a"
  fi

  ( cd "$WS" && $prefix dart --packages="$WS/.dart_tool/package_config.json" \
      "$WS/packages/oka/bin/oka.dart" run dev \
      --project "$APP_ROOT" --platform linux --no-watch \
      --probes "$OUT/probes-linux.json" \
      < "$fifo" > "$log" 2>&1 ) &
  local session=$!
  exec 3> "$fifo"

  wait_for "$log" 'dev: ready' 360 "dev session (linux)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }

  edit_file || { echo 'FAIL: edit (linux)'; FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }
  echo "r $APP_ROOT/$UNIT_FILE" >&3
  wait_for "$log" 'reload 1: OK' 120 "hot reload (linux)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }
  grep -qE 'feature-v1 -> feature-v2-live|probe.*feature-v2-live' "$log" \
    || { echo 'FAIL: probe did not flip (linux)'; FAILED=1; }

  echo 'R' >&3
  wait_for "$log" 'restart: OK' 180 "hot restart (linux)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }

  echo 'q' >&3
  exec 3>&-
  wait "$session" 2>/dev/null
  restore
}

pkill_pattern "build/linux.*/bundle/example"
sleep 1

FLUTTER_HEAD="$($FLUTTER_BIN --version 2>/dev/null | head -1 | sed 's/ • .*//')"
echo "== gate_run_dev_linux host: $(uname -m) flutter=${FLUTTER_HEAD:-unknown}"
run_leg

if [ "$FAILED" -eq 0 ]; then
  echo 'gate: linux desktop dev session (reload + restart) — ALL PASS'
else
  echo 'gate: linux desktop dev session — FAILED'
fi
exit $FAILED
