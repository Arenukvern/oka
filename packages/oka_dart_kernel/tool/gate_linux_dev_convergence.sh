#!/usr/bin/env bash
# L0 entry: Linux Flutter desktop dev convergence (reload + assets).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FAILED=0
bash "$HERE/gate_run_dev_linux.sh" || FAILED=1
bash "$HERE/gate_dev_assets_linux.sh" || FAILED=1
if [ "$FAILED" -eq 0 ]; then
  echo 'gate: linux dev convergence L0 — ALL PASS'
else
  echo 'gate: linux dev convergence L0 — FAILED'
fi
exit $FAILED
