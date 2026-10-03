#!/usr/bin/env bash
# Kernel/live-stack benchmarks (composition loop, delta pipeline, AOT exe).
# Machine JSON on stdout; see packages/oka_dart_kernel/tool/bench_live.dart.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OKA_ROOT="$ROOT_DIR"
cd "$ROOT_DIR/packages/oka_dart_kernel"
exec dart tool/bench_live.dart "$@"
