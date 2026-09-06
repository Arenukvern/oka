#!/usr/bin/env bash
# Build performance benchmarks for oka (ADR-0007 evidence surface).
#
# Measures wall-clock times for the agent loop primitives against a target
# Flutter project (default: ./example):
#   explain     — validated plan, zero tool invocations (cold)
#   build       — incremental (warm .oka_cache) full debug APK build
#   compare     — artifact byte-equivalence gate (self-compare)
#   debug_step  — single-step probe (resolve-abis prefix)
#
# Timings are machine- and environment-dependent; each summary records the
# environment so runs are comparable only against similar setups.
# Results land in .steward/benchmark-summaries/ (gitignored; evidence docs
# summarize them).
#
# Usage: tool/benchmarks/build_benchmarks.sh [project-dir] [--cold]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="${1:-$ROOT_DIR/example}"
COLD=false
[[ "${2:-}" == "--cold" ]] && COLD=true

if [[ ! -f "$PROJECT_DIR/pubspec.yaml" ]]; then
  echo "benchmarks: not a Flutter project: $PROJECT_DIR" >&2
  exit 2
fi

# Runner: prefer the globally installed snapshot; fall back to dart run.
RUNNER_LABEL="dart-run"
OKA_ARGS=()
if command -v oka >/dev/null 2>&1 && oka --version >/dev/null 2>&1; then
  RUNNER_LABEL="global-snapshot"
  OKA_ARGS=()
  run_oka() { oka "$@"; }
else
  run_oka() { (cd "$ROOT_DIR" && dart run bin/oka.dart "$@"); }
fi

mkdir -p "$ROOT_DIR/.steward/benchmark-summaries"
TIMESTAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
OUT="$ROOT_DIR/.steward/benchmark-summaries/build-benchmarks-$TIMESTAMP.json"

time_step() {
  local label="$1"; shift
  local start end
  start="$(python3 -c 'import time; print(time.time())')"
  if ! "$@" >/dev/null 2>&1; then
    echo "benchmarks: step '$label' failed" >&2
    return 1
  fi
  end="$(python3 -c 'import time; print(time.time())')"
  python3 -c "print(f'{$end - $start:.2f}')"
}

echo "🔬 oka build benchmarks — project: $PROJECT_DIR (runner: $RUNNER_LABEL)"

COLD_NOTE="false"
if $COLD; then
  COLD_NOTE="true"
  CACHE="$PROJECT_DIR/.oka_cache"
  if [[ -d "$CACHE" ]]; then
    echo "  --cold: moving .oka_cache aside (restored after run)"
    mv "$CACHE" "$CACHE.bench-backup"
  fi
fi
restore_cache() {
  if $COLD && [[ -d "$PROJECT_DIR/.oka_cache.bench-backup" ]]; then
    rm -rf "$PROJECT_DIR/.oka_cache"
    mv "$PROJECT_DIR/.oka_cache.bench-backup" "$CACHE"
  fi
}
trap restore_cache EXIT

# Warm-up (also guarantees a warm cache for the incremental measurement)
run_oka explain >/dev/null

EXPLAIN_S="$(time_step explain run_oka explain)"
BUILD_S="$(time_step incremental-build run_oka build apk)"
APK="$PROJECT_DIR/.oka_cache/build/debug/app-debug.apk"
COMPARE_S="$(time_step compare run_oka compare "$APK" "$APK" --quiet)"
STEP_S="$(time_step debug-step run_oka debug step resolve-abis)"

OKA_VERSION="$( (oka --version 2>/dev/null || dart run "$ROOT_DIR/bin/oka.dart" --version) | tr -d '[:space:]' | sed 's/Oka version //' )"
FLUTTER_VERSION="$(flutter --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frameworkVersion",""))' 2>/dev/null || echo unknown)"
OS_NAME="$(uname -s) $(uname -m)"
OKA_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

python3 - "$OUT" "$EXPLAIN_S" "$BUILD_S" "$COMPARE_S" "$STEP_S" "$OKA_VERSION" "$FLUTTER_VERSION" "$OS_NAME" "$OKA_COMMIT" "$RUNNER_LABEL" "$COLD_NOTE" <<'PYEOF'
import json, sys
(out, explain, build, compare, step, oka_v, fl_v, os_name, commit, runner, cold) = sys.argv[1:]
doc = {
  "schema": "oka/build-benchmarks/v1",
  "timestamp": out.split("build-benchmarks-")[1].removesuffix(".json"),
  "project": "example",
  "runner": runner,
  "cold": cold == "true",
  "results_seconds": {
    "explain": float(explain),
    "incremental_build_apk": float(build),
    "compare_self": float(compare),
    "debug_step_resolve_abis": float(step),
  },
  "environment": {
    "oka_version": oka_v,
    "oka_commit": commit,
    "flutter_version": fl_v,
    "os": os_name,
    "note": "machine-dependent; compare only against similar setups",
  },
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(json.dumps(doc["results_seconds"], indent=2))
PYEOF
echo "📄 summary: $OUT"
