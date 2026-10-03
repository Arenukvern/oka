#!/usr/bin/env bash
# ADR-0032 G3-real: the per-unit delta lane live-patching the REAL app
# (~/xs/storage_problem/last_answer). The patch edits a real module —
# headless_core's DocReplicaStore ctor default — and the running driver
# picks it up via `_reloadKernel(kernelFilePath)` with no restart. The
# delta is compiled by oka's own pipeline (gate_pipeline --delta) against
# the checkout of the SAME version as the app's VM — the frontend_server's
# incremental output is not a valid reload payload (see evidence doc).
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_ROOT=${APP_ROOT:-$HOME/xs/storage_problem/last_answer}
[ -f "$APP_ROOT/.dart_tool/package_config.json" ] || {
  echo 'app has no .dart_tool/package_config.json'; exit 1; }

cd "$PKG_DIR"
# Restore a patch leftover from a killed run (SIGTERM skips the finally).
sed -i '' "s/doc_replicas_live/doc_replicas/" \
  "$APP_ROOT/packages/headless_core/lib/src/doc_replica_store.dart" || true

APP_DART="$(dirname "$(readlink -f "$(which dart)")")/dart"
APP_DART_VERSION=$("$APP_DART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LANG_VERSION=$(echo "$APP_DART_VERSION" | cut -d. -f1-2)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$APP_DART_VERSION}
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
GATE_DIR="$PKG_DIR/.gate_real_app"
VM_PLATFORM="$(dirname "$APP_DART")/../lib/_internal/vm_platform_strong.dill"
[ -f "$VM_PLATFORM" ] || { echo "missing: $VM_PLATFORM"; exit 1; }

echo "=== [g3-real 1/2] pipeline package_config (checkout $APP_DART_VERSION, sdk_hash $SDK_HASH)"
DELTA_PACKAGES=$(bash tool/pipeline_packages_config.sh "$CHECKOUT" "$LANG_VERSION" "$GATE_DIR")

echo "=== [g3-real 2/2] live per-unit reload (stock 3.13.2 VM)"
G3_ENTRY="$APP_ROOT/tool/oka_kernel_driver.dart" \
G3_PACKAGES="$APP_ROOT/.dart_tool/package_config.json" \
G3_UNIT_FILE="$APP_ROOT/packages/headless_core/lib/src/doc_replica_store.dart" \
G3_OLD="this.dir = 'doc_replicas'" \
G3_NEW="this.dir = 'doc_replicas_live'" \
G3_EXPECT="store.dir=doc_replicas_live" \
G3_PORT=8183 \
G3_APP_DART="$APP_DART" \
G3_DELTA_DART="$APP_DART" \
G3_DELTA_PACKAGES="$DELTA_PACKAGES" \
G3_DELTA_CWD="$PKG_DIR" \
G3_SDK_HASH="$SDK_HASH" \
DART_SDK_SUMMARY="$VM_PLATFORM" \
DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json" \
OKA_TARGET=vm \
  dart tool/g3_live_reload.dart
