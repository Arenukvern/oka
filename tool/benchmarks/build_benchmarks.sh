#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OKA_ROOT="$ROOT_DIR"
exec dart "$ROOT_DIR/tool/benchmarks/build_benchmarks.dart" "$@"
