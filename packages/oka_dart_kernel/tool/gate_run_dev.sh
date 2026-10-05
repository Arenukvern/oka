#!/usr/bin/env bash
# The converged dev session gate (ADR-0037 §6 / G-AC8 r-R UX): `oka run
# dev` boots last_answer itself, then
#
#   r  = oka's unit-delta lane (the developer's plain file save, compiled
#        by the app's own frontend, applied over the VM service with
#        reassemble; on web via dwds) — the probe must FLIP,
#   R  = the platform hot restart — the session must report OK,
#   q  = clean quit.
#
# macOS leg runs the real Flutter desktop app; web leg runs the real web
# (DDK) app in Chrome. No emulators, no devices.
#
# Usage: tool/gate_run_dev.sh   (env: LIVE_APP_ROOT, FLUTTER_BIN)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_run_dev"
APP_ROOT=${LIVE_APP_ROOT:-$HOME/xs/storage_problem/last_answer}
WS=$(cd "$HERE/../.." && pwd)
. "$HERE/tool/gate_lib.sh"
export FLUTTER_BIN=${FLUTTER_BIN:-$HOME/fvm/default/bin/flutter}
mkdir -p "$OUT"
FAILED=0

UNIT_FILE="packages/headless_core/lib/src/fractional_order.dart"
FIND='  return String.fromCharCodes([
    for (final digit in mid) _alphabet.codeUnitAt(digit),
  ]);'
REPLACE='  const patchedAlphabet = '"'"'acbdefghijklmnopqrstuvwxyz'"'"';
  return String.fromCharCodes([
    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),
  ]);'

restore() {
  restore_marker "$APP_ROOT/$UNIT_FILE" \
    "const patchedAlphabet = 'acbdefghijklmnopqrstuvwxyz';" ""
  restore_marker "$APP_ROOT/$UNIT_FILE" \
    "patchedAlphabet.codeUnitAt(digit)" "_alphabet.codeUnitAt(digit)"
}
trap restore EXIT
restore

write_probes() {
  # DDS evaluate (desktop + web) returns strings UNQUOTED — expect 'c'.
  cat > "$OUT/probes-macos.json" <<'EOF'
[{"library": "fractional_order.dart", "expression": "fractionalBetween('a', null)", "expect": "c"}]
EOF
  cat > "$OUT/probes-web.json" <<'EOF'
[{"library": "fractional_order.dart", "expression": "fractionalBetween('a', null)", "webExpression": "String(dartDevEmbedder.importLibrary('package:headless_core/src/fractional_order.dart').fractionalBetween('a', null))", "expect": "c"}]
EOF
}

# The developer's plain save: body-only marker edit (same discipline as
# gate_endless_loop — function bodies, never const fields).
edit_file() {
  perl -0777 -pi -e 'BEGIN {
    $f = "  return String.fromCharCodes([\n    for (final digit in mid) _alphabet.codeUnitAt(digit),\n  ]);";
    $r = "  const patchedAlphabet = \x27acbdefghijklmnopqrstuvwxyz\x27;\n  return String.fromCharCodes([\n    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),\n  ]);";
  } s/\Q$f\E/$r/' "$APP_ROOT/$UNIT_FILE"
  grep -q "patchedAlphabet" "$APP_ROOT/$UNIT_FILE"
}

# leg <platform> [extra flags...]
leg() {
  local platform="$1"; shift
  local log="$OUT/$platform.log"
  local fifo="$OUT/$platform.in"
  echo "== leg: $platform"
  write_probes
  restore
  rm -f "$fifo"; mkfifo "$fifo"

  ( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
      "$WS/packages/oka/bin/oka.dart" run dev \
      --project "$APP_ROOT" --platform "$platform" --no-watch \
      --probes "$OUT/probes-$platform.json" \
      "$@" < "$fifo" > "$log" 2>&1 ) &
  local session=$!
  exec 3> "$fifo"

  wait_for "$log" 'dev: ready' 240 "dev session ($platform)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }

  # r — the developer's plain save, applied by the oka delta lane.
  edit_file || { echo "FAIL: edit ($platform)"; FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }
  echo "r $APP_ROOT/$UNIT_FILE" >&3
  wait_for "$log" 'reload 1: OK' 120 "hot reload ($platform)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }
  grep -q 'b -> c' "$log" || { echo "FAIL: probe did not flip ($platform)"; FAILED=1; }

  # R — the platform hot restart.
  echo 'R' >&3
  wait_for "$log" 'restart: OK' 180 "hot restart ($platform)" 5 \
    || { FAILED=1; exec 3>&-; kill "$session" 2>/dev/null; restore; return 0; }

  # q — clean quit.
  echo 'q' >&3
  exec 3>&-
  wait "$session" 2>/dev/null
  restore
}

leg macos
leg web --port 8188 --open-browser

if [ "$FAILED" -eq 0 ]; then
  echo 'gate: converged dev session (macos + web) — ALL PASS'
else
  echo 'gate: converged dev session — FAILED'
fi
exit $FAILED
