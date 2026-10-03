#!/usr/bin/env bash
# ADR-0032 G3: live per-unit reload — oka's --delta pipeline compiles the
# patched unit as the reload root; the app applies it via _reloadKernel.
# The orchestrator is pure dart:io; the delta compile needs the checkout
# kernel stack (tool/pipeline_packages_config.sh) and the host platform dill.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST_DART="$(dirname "$(readlink -f "$(which dart)")")/dart"
HOST_DART_VERSION=$("$HOST_DART" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LANG_VERSION=$(echo "$HOST_DART_VERSION" | cut -d. -f1-2)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$HOST_DART_VERSION}
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
GATE_DIR=".gate_g3"
VM_PLATFORM="$(dirname "$HOST_DART")/../lib/_internal/vm_platform_strong.dill"
[ -f "$VM_PLATFORM" ] || { echo "missing: $VM_PLATFORM"; exit 1; }

DELTA_PACKAGES=$(bash tool/pipeline_packages_config.sh "$CHECKOUT" "$LANG_VERSION" "$GATE_DIR")

G3_DELTA_DART="$HOST_DART" \
G3_DELTA_PACKAGES="$DELTA_PACKAGES" \
G3_DELTA_CWD="$PWD" \
G3_SDK_HASH="$SDK_HASH" \
DART_SDK_SUMMARY="$VM_PLATFORM" \
DART_PACKAGES_CONFIG="$PWD/.dart_tool/package_config.json" \
OKA_TARGET=vm \
  dart tool/g3_live_reload.dart
