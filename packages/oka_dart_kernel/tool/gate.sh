#!/usr/bin/env bash
# Gate runner for ADR-0032 (kernel-graph ownership). Runs every implemented
# gate in order and prints a summary. See skills/oka-kernel for the manual.
#
# Usage: gate.sh [g1b|g2|g25|g3|g4|all]   (default: all implemented)
#
# Plain variables, not `declare -A`: gate.sh must run on macOS's stock bash
# 3.2, which has no associative arrays.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

GATES=${1:-all}
R_G1B=SKIP; R_G2=SKIP; R_G25=SKIP; R_G3=SKIP; R_G4=SKIP
run() { echo; echo "==================== $1 ===================="; shift; bash "$@"; }

if [ "$GATES" = all ] || [ "$GATES" = g1b ] || [ "$GATES" = g2 ]; then
  run "G1b+G2 pipeline (host: acceptance + execution)" "$HERE/gate_g1b_g2.sh" \
    && R_G1B=PASS && R_G2=PASS || { R_G1B=FAIL; R_G2=FAIL; }
fi

if [ "$GATES" = all ] || [ "$GATES" = g25 ]; then
  run "G2.5 multi-unit split (docker linux)" "$HERE/gate_g25_linux.sh" \
    && R_G25=PASS || R_G25=FAIL
fi

if [ "$GATES" = all ] || [ "$GATES" = g3 ]; then
  run "G3 live reload (frontend_server + vm_service)" "$HERE/gate_g3.sh" \
    && R_G3=PASS || R_G3=FAIL
fi

if [ "$GATES" = all ] || [ "$GATES" = g4 ]; then
  run "G4 web lane (chunks + pointer + transfer verification)" "$HERE/gate_g4_web.sh" \
    && R_G4=PASS || R_G4=FAIL
fi

echo
echo "==================== SUMMARY ===================="
echo "g1b: $R_G1B"
echo "g2:  $R_G2"
echo "g25: $R_G25"
echo "g3:  $R_G3"
echo "g4:  $R_G4"
[ "$R_G1B" != FAIL ] && [ "$R_G2" != FAIL ] && [ "$R_G25" != FAIL ] \
  && [ "$R_G3" != FAIL ] && [ "$R_G4" != FAIL ]
