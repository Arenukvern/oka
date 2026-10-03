#!/usr/bin/env bash
# Shared gate helpers (ADR-0036 Tier 0): source this, never execute it.
#
# Gates keep only leg sequencing + PASS/FAIL collection; bring-up, patch,
# and verify discipline lives in the Dart drivers the gates call. Plain
# variables only: must run on macOS stock bash 3.2.

# wait_for <log> <pattern> <tries> <label> [interval-secs]
# Succeeds once <log> contains <pattern>; fails after <tries> polls.
wait_for() {
  local i=0 interval=${5:-5}
  while [ $i -lt "$3" ]; do
    if grep -q "$2" "$1" 2>/dev/null; then return 0; fi
    sleep "$interval"; i=$((i+1))
  done
  echo "gate: timeout waiting for $4 (pattern: $2, log: $1)" >&2
  return 1
}

# kill_port <port> — best-effort: kill whatever holds the TCP port.
kill_port() {
  lsof -ti "$1" 2>/dev/null | xargs kill 2>/dev/null || true
}

# pkill_pattern <pattern> — best-effort pkill -f.
pkill_pattern() {
  pkill -f "$1" 2>/dev/null || true
}

# restore_marker <file> <from> <to> — revert one live-patch marker
# (best-effort: a missing file or absent marker is not an error).
restore_marker() {
  sed -i '' "s/$2/$3/g" "$1" 2>/dev/null || true
}

# require_env <NAME> [<NAME>…] — fail loudly before a leg starts.
require_env() {
  for name in "$@"; do
    if [ -z "$(eval "echo \$$name")" ]; then
      echo "gate: required env $name is not set" >&2
      return 1
    fi
  done
}
