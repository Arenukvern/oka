#!/usr/bin/env bash
# L0 entry: Linux Flutter desktop dev convergence (reload + assets).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WS=$(cd "$HERE/../.." && pwd)
export FLUTTER_BIN=${FLUTTER_BIN:-$(command -v flutter)}
exec dart --packages="$WS/.dart_tool/package_config.json" \
  "$HERE/tool/gate_linux_dev.dart" --leg all
