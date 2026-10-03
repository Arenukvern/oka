#!/usr/bin/env bash
# ADR-0032 G3-real-B: the per-unit delta lane against the REAL Flutter app
# under `flutter run -d macos` (DDS transport).
#
# Patch: headless_core's fractional-order alphabet (`_alphabet`), a real
# module constant. `evaluate` in the running app's library scope returns
# fractionalBetween('a', null) — 'b' before, 'c' after the live patch.
#
# Delta lane: G3B_DELTA_MODE=unit — oka's own pipeline compiles the patched
# unit's library as the reload root (kernelForProgram + prune to the unit),
# so the delta is unit-sized. G3B_DELTA_MODE=fs reproduces the stock
# frontend_server lane for research (delta = whole component; documented
# negative: 135MB, refused by the VM's kernel isolate).
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER=${FLUTTER:-/Users/antonio/fvm/default}
APP_ROOT=${APP_ROOT:-$HOME/xs/storage_problem/last_answer}

cd "$PKG_DIR"
# Restore a patch leftover from a killed run (SIGTERM skips the finally).
sed -i '' "s/acbdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/" \
  "$APP_ROOT/packages/headless_core/lib/src/fractional_order.dart" || true

FDART="$FLUTTER/bin/cache/dart-sdk/bin/dart"
FDART_VERSION=$("$FDART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LANG_VERSION=$(echo "$FDART_VERSION" | cut -d. -f1-2)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$FDART_VERSION}
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
GATE_DIR="$PKG_DIR/.gate_real_flutter"

echo "=== [g3-B 1/2] pipeline package_config (checkout $FDART_VERSION, sdk_hash $SDK_HASH)"
DELTA_PACKAGES=$(bash tool/pipeline_packages_config.sh "$CHECKOUT" "$LANG_VERSION" "$GATE_DIR")

echo "=== [g3-B 2/2] live per-unit reload through flutter run + DDS"
# Compile-time env for the unit delta subprocess (inherited):
#   DART_SDK_SUMMARY     host patched-SDK platform dill (the macos debug
#                        app is JIT-compiled against it by flutter run)
#   DART_PACKAGES_CONFIG the app's own package config (import URIs match)
#   OKA_TARGET=flutter   FlutterTarget (patched SDK lacks stock-VM libs)
export DART_SDK_SUMMARY="$FLUTTER/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill"
export DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json"
export OKA_TARGET=flutter

G3B_APP_ROOT="$APP_ROOT" \
G3B_FLUTTER="$FLUTTER" \
G3B_ENTRY="$APP_ROOT/lib/main.dart" \
G3B_UNIT_FILE="$APP_ROOT/packages/headless_core/lib/src/fractional_order.dart" \
G3B_MAX_DELTA_BYTES=8388608 \
G3B_DELTA_MODE=unit \
G3B_DELTA_DART="$FDART" \
G3B_DELTA_PACKAGES="$DELTA_PACKAGES" \
G3B_DELTA_CWD="$PKG_DIR" \
G3B_SDK_HASH="$SDK_HASH" \
G3B_OLD="const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';" \
G3B_NEW="const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';" \
G3B_EXPR="fractionalBetween('a', null)" \
G3B_BEFORE="b" \
G3B_AFTER="c" \
G3B_RPC_MINUTES=15 \
  dart tool/g3_flutter_reload.dart
