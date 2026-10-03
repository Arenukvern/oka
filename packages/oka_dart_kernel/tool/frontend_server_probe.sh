#!/usr/bin/env bash
# Hand-driven frontend_server incremental session: compile an entry, report
# the boundary key and emitted dill. The full compile/recompile/accept loop
# (delta dills) is demonstrated in the recorded spike run — see
# docs/evidence/deferred-patch-units-spike-2026-10-01.mdx §9.
#
# Usage: frontend_server_probe.sh <entry.dart>
set -euo pipefail
SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(which dart)")")")}
FS="$SDK/bin/snapshots/frontend_server_aot.dart.snapshot"
ENTRY=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
PLATFORM="$SDK/lib/_internal/vm_platform_strong.dill"

( printf 'compile %s\n' "$ENTRY"; sleep 15; printf 'quit\n' ) | \
  "$SDK/bin/dartaotruntime" "$FS" \
    --incremental \
    --sdk-root="$SDK/" \
    --platform="$PLATFORM" 2>&1 | sed -n '1,40p'

echo "emitted: ${ENTRY%.dart}.dill"
ls -la "${ENTRY%.dart}.dill"
