#!/usr/bin/env bash
# L0: dev-session asset + delta lanes on Linux desktop (example app).
# Dart-owned driver — no pattern-kill cleanup.
#
# Usage: tool/gate_dev_assets_linux.sh
# Env: FLUTTER_BIN, OKA_LINUX_DEV_GATE_USE_XVFB=1
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WS=$(cd "$HERE/../.." && pwd)
export FLUTTER_BIN=${FLUTTER_BIN:-$(command -v flutter)}
if [ -z "$FLUTTER_BIN" ] || ! command -v "$FLUTTER_BIN" >/dev/null; then
  echo 'gate: FLUTTER_BIN/flutter not found' >&2
  exit 1
fi
exec dart --packages="$WS/.dart_tool/package_config.json" \
  "$HERE/tool/gate_linux_dev.dart" --leg assets
