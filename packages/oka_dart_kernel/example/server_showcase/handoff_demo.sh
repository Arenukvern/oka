#!/usr/bin/env bash
# Lane S3 empirical demo (ADR-0035): snapshot swap with SO_REUSEPORT
# handoff. A probe loop hammers the port across the swap; the result must
# be zero refused connections and labels v1 -> v2 with no gap.
#
# The "new snapshot" is simulated by an env label (the swap is a process
# mechanic; the code difference is orthogonal to the handoff).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=8254
DART_BIN=${OKA_BENCH_DART:-$(command -v dart)}

kill_by_port() { # best-effort per-platform port cleanup
  lsof -ti :$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
  fuser -k $PORT/tcp 2>/dev/null || true
}
kill_by_port
sleep 1

OKA_HANDOFF_LABEL=v1 "$DART_BIN" "$HERE/handoff_server.dart" \
  > "$HERE/.build/handoff_v1.log" 2>&1 &
V1_PID=$!
sleep 2

# The probe loop: no connection may be refused across the swap.
"$DART_BIN" "$HERE/probe.dart" "$PORT" 60 > "$HERE/.build/probes.log" 2>&1 &
PROBE_PID=$!

OKA_HANDOFF_LABEL=v2 "$DART_BIN" "$HERE/handoff_server.dart" \
  > "$HERE/.build/handoff_v2.log" 2>&1 &
V2_PID=$!
sleep 2
# Drain v1 — the exact process launched above, not just any pid on the port.
kill -TERM "$V1_PID" 2>/dev/null || true
wait $PROBE_PID || true
sleep 1

OK=$(grep -c "^OK" "$HERE/.build/probes.log" || true)
REFUSED=$(grep -c "REFUSED" "$HERE/.build/probes.log" || true)
V1_SEEN=$(grep -c "handoff: v1" "$HERE/.build/probes.log" || true)
V2_SEEN=$(grep -c "handoff: v2" "$HERE/.build/probes.log" || true)
echo "handoff demo: probes ok=$OK refused=$REFUSED v1=$V1_SEEN v2=$V2_SEEN"
kill_by_port
if grep -q "Address already in use" "$HERE/.build/handoff_v2.log" 2>/dev/null; then
  echo "handoff demo: v2 could not bind — on this platform dart 'shared:' is"
  echo "  SO_REUSEADDR, not SO_REUSEPORT; the listener handoff needs linux"
  echo "  (or fd passing). Run this demo in linux for the PASS."
  exit 2
fi
# The pass: zero refused connections across the swap, and the new snapshot
# served traffic. (Linux reuseport shifts traffic to the newest listener as
# soon as it binds, so v1 may serve zero probes once v2 is up — recorded,
# not gated.)
[ "$REFUSED" = "0" ] && [ "$V2_SEEN" -gt 0 ]
