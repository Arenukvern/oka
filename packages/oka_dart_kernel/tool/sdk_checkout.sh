#!/usr/bin/env bash
# Shared provisioner for the pinned dart-lang/sdk checkout (ADR-0032).
# Source this file; it sets CHECKOUT, SDK, DART_VERSION, SDK_HASH, HOST_OS.
#
# Env: OKA_SDK_CHECKOUT overrides the checkout location.
set -euo pipefail

SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
export DART_SDK_ROOT="$SDK"
DART_VERSION=$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$DART_VERSION}

case "$(uname -s)" in
  Darwin) HOST_TARGET_OS=macos ;;
  Linux) HOST_TARGET_OS=linux ;;
  *) HOST_TARGET_OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac

if [ ! -f "$CHECKOUT/pkg/kernel/lib/kernel.dart" ]; then
  mkdir -p "$(dirname "$CHECKOUT")"
  echo "sdk_checkout: cloning dart-lang/sdk (shallow, tag $DART_VERSION) -> $CHECKOUT"
  git clone --depth 1 --branch "$DART_VERSION" \
    https://github.com/dart-lang/sdk.git "$CHECKOUT"
fi
[ -f "$CHECKOUT/pkg/kernel/lib/kernel.dart" ] || { echo 'pkg/kernel missing in checkout'; exit 1; }

SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
export SDK_HASH CHECKOUT DART_VERSION HOST_TARGET_OS SDK
