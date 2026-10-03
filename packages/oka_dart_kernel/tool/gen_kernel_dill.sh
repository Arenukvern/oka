#!/usr/bin/env bash
# Build a kernel dill for a Dart entrypoint using the local SDK's gen_kernel
# (the same frontend dartdev uses), leaving deferred imports intact.
#
# Usage: gen_kernel_dill.sh <entry.dart> <out.dill> [target-os]
set -euo pipefail

SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
# Homebrew layout: bin/dart -> libexec/bin/dart; SDK root holds lib/_internal.
if [ ! -f "$SDK/lib/_internal/vm_platform_strong.dill" ]; then
  SDK=$(dirname "$(dirname "$(readlink -f "$(which dart)")")")
fi
GK="$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot"
case "$(uname -s)" in
  Darwin) HOST_TARGET_OS=macos ;;
  Linux) HOST_TARGET_OS=linux ;;
  *) HOST_TARGET_OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
TARGET_OS=${3:-$HOST_TARGET_OS}

"$SDK/bin/dartaotruntime" "$GK" \
  --platform="$SDK/lib/_internal/vm_platform_strong.dill" \
  --aot --packages="$(dart pub get --directory "$(dirname "$1")" >/dev/null 2>&1; echo "$(dirname "$1")/.dart_tool/package_config.json")" \
  --target-os="$TARGET_OS" \
  -o "$2" "$1"
echo "dill: $2"
