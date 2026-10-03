#!/usr/bin/env bash
# gen_snapshot --loading_unit_manifest probe: emit per-unit AOT ELFs + JSON
# manifest from a dill with deferred imports (ADR-0032 context; evidence in
# docs/evidence/deferred-patch-units-spike-2026-10-01.mdx §8).
#
# Usage: loading_units_probe.sh <program.dill> <out-dir>
set -euo pipefail
SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
DILL=$1
OUT=$2
mkdir -p "$OUT"

"$SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/units.so" \
  --loading_unit_manifest="$OUT/units_manifest.json" \
  "$DILL"

echo "units emitted:"
ls -la "$OUT"
echo "--- manifest ---"
cat "$OUT/units_manifest.json"
