#!/usr/bin/env bash
# Builds the AOT pipeline exe: `dart compile exe` of gate_pipeline with the
# pinned checkout's kernel stack (pkg/kernel/vm/front_end via the merged
# package config) and the checkout's sdk_hash baked in as a compile-time
# define. Output is byte-identical to the JIT `dart tool/gate_pipeline.dart`
# path and ~7-11x faster per invocation (measured 2026-10-03: delta 3.9s ->
# 0.6s, full compile 5.3s -> 0.5s on the toy app).
#
# Usage: tool/build_pipeline_exe.sh <SDK_CHECKOUT> <LANG_VERSION> <OUT_EXE>
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECKOUT=$1
LANG_VERSION=$2
OUT_EXE=$3

PKG=$( ( cd "$HERE" && bash tool/pipeline_packages_config.sh "$CHECKOUT" "$LANG_VERSION" "$(dirname "$OUT_EXE")" ) | tail -1 )
SDK_HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)

# `-Dsdk_hash` is read by the checkout's kernel stack as a const-from-
# environment; it must be baked into THIS compilation.
dart compile exe "$HERE/tool/gate_pipeline.dart" \
  -o "$OUT_EXE" \
  --packages="$PKG" \
  "-Dsdk_hash=$SDK_HASH" 1>&2
echo "$OUT_EXE"
