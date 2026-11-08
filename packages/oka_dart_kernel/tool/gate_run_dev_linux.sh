#!/usr/bin/env bash
# L0: converged dev session on Linux desktop (example app).
# Dart-owned driver — no pattern-kill cleanup.
#
# Usage: tool/gate_run_dev_linux.sh
# Env: FLUTTER_BIN, OKA_LINUX_DEV_GATE_USE_XVFB=1
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WS=${WS:-$(cd "$HERE/../.." && pwd)}
export FLUTTER_BIN=${FLUTTER_BIN:-$(command -v flutter)}
if [ -z "$FLUTTER_BIN" ] || ! command -v "$FLUTTER_BIN" >/dev/null; then
  echo 'gate: FLUTTER_BIN/flutter not found — install Flutter linux desktop' >&2
  exit 1
fi
exec dart --packages="$WS/.dart_tool/package_config.json" \
  "$HERE/tool/gate_linux_dev.dart" --leg reload
