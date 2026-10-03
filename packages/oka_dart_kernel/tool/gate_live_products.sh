#!/usr/bin/env bash
# Product-families gate (ADR-0035 §2e): one composition API, three real
# products — the oka CLI itself (plain Dart CLI), mcp_flutter's fmtk
# MCP server (long-running stdio), vosges (Flutter desktop app). Each leg
# patches its product mid-run / mid-session / mid-boot and proves a probe
# flip, a continuity hold (same pid), and a product-visible flip.
#
# Usage: tool/gate_live_products.sh
# Env: OKA_ROOT, MCP_FLUTTER_ROOT, VOSGES_APP_ROOT, FLUTTER_BIN,
#      OKA_SDK_CHECKOUT, OKA_SDK_CHECKOUT_FLUTTER
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$HERE/tool"
OUT="$HERE/.gate_products"
WS=$(cd "$HERE/../.." && pwd)
. "$TOOL/gate_lib.sh"
mkdir -p "$OUT"
FAILED=0

pkill_pattern "flutter_mcp_toolkit_server.dart"
pkill_pattern "vosges_desktop"
sleep 1

leg() {
  local name="$1" script="$2" log="$OUT/$1.log"
  echo "== leg: $name"
  ( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
      "$TOOL/$script" ) 2>&1 | tee "$log"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    FAILED=1
    echo "!! $name FAILED (log: $log)"
  fi
}

leg oka-cli live_products_oka_cli.dart
leg mcp-stdio live_products_mcp_stdio.dart
leg flutter-app live_products_flutter_app.dart

if [ "$FAILED" -eq 0 ]; then
  echo 'gate: live product families — ALL PASS'
else
  echo 'gate: live product families — FAILED'
fi
exit $FAILED
