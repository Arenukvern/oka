#!/usr/bin/env bash
# Local p1 matrix: linux/macOS × x64/arm64 where the host can run a cell.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

uname_s="$(uname -s)"
uname_m="$(uname -m)"
cell="${uname_s}/${uname_m}"

skip() {
  echo "SKIP $cell — $1"
  exit 0
}

case "$uname_s" in
  Linux|Darwin) ;;
  *) skip "posix-perl backend is Linux/macOS only" ;;
esac

export OWNED_SESSION_P1_LEADER="${OWNED_SESSION_P1_LEADER:-$ROOT/tool/owned_session_p1_leader.pl}"
if [[ ! -f "$OWNED_SESSION_P1_LEADER" ]]; then
  echo "FAIL $cell — leader missing at $OWNED_SESSION_P1_LEADER"
  exit 1
fi

echo "RUN $cell — dart test (p1 + package)"
dart test
echo "RUN $cell — p1 probes"
bash "$ROOT/tool/run_p1_oka_probes.sh"
echo "PASS $cell"
