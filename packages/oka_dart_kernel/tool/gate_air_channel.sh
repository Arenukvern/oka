#!/usr/bin/env bash
# The air channel end-to-end on last_answer's real engine (ADR-0037
# G-AC7): units declared once, an invisible ship derived from the working
# tree, the channel materialized as a git branch, and the FETCHED delta
# applied to the running engine — one pid, boot state held.
#
# App-specific facts live HERE (thin shell, ADR-0036 Tier 0) and are
# materialized into a scratch git WORKTREE of last_answer at HEAD: the
# user's checkout (often carrying WIP) is never touched; the adoption
# commit (tool/patch_units.dart) lives only in the worktree's detached
# HEAD. The driver (air_channel_e2e.dart) knows no app.
#
# Usage: tool/gate_air_channel.sh
#   (env: LIVE_APP_ROOT, OKA_SDK_CHECKOUT; needs ~40MB of temp space)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WS=$(cd "$HERE/../.." && pwd)
APP_ROOT=${LIVE_APP_ROOT:-$HOME/xs/storage_problem/last_answer}
# Sibling path deps (`../dart_flutter_packages/...`, `../../ecsly/...`)
# resolve relative to the repo root; the worktree therefore lives at the
# SAME depth as the repo (hidden dir next to it), so they just work.
APP_PARENT=$(dirname "$APP_ROOT")
OUT="$HERE/.gate_air"
WT="$APP_PARENT/.oka-air-wt"
ORIGIN=/tmp/oka-air-origin
ORIGIN_BARE=/tmp/oka-air-origin.git
PORT=8244
. "$HERE/tool/gate_lib.sh"
rm -rf "$OUT" "$ORIGIN" "$ORIGIN_BARE"; mkdir -p "$OUT"

cleanup() {
  pkill_pattern "oka_endless_driver.dart --serve" || true
  git -C "$APP_ROOT" worktree remove --force "$WT" 2>/dev/null || true
}
trap cleanup EXIT

echo '== [1/7] BARE origin repo + last_answer worktree at HEAD'
git init -q -b main "$ORIGIN"
printf 'origin\n' > "$ORIGIN/README.md"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" -c user.name=gate -c user.email=gate@local commit -qm init
git init -q --bare -b main "$ORIGIN_BARE"
git -C "$ORIGIN" push -q "$ORIGIN_BARE" main
rm -rf "$ORIGIN"
git -C "$APP_ROOT" worktree add --detach "$WT" HEAD >/dev/null || {
  echo 'FAIL: worktree add'; exit 1; }

echo '== [2/7] the adoption: the APP declares its units once'
cat > "$WT/tool/patch_units.dart" <<'EOF'
/// The unit declaration (ADR-0037 §1): declared ONCE; every patch after
/// this is derived by `oka ship` from the working tree and the channel
/// state. Plain classes — the units probe reads the shape structurally,
/// so adoption needs no package dependency.
library;

class _Unit {
  final String name;
  final List<String> libraries;
  const _Unit(this.name, this.libraries);
}

class _Units {
  final String revision;
  final List<_Unit> units;
  const _Units(this.revision, this.units);
}

final patchUnits = _Units('baseline', [
  _Unit('engine', [
    'packages/headless_core/lib/src/fractional_order.dart',
    'packages/headless_core/lib/src/doc_replica_store.dart',
  ]),
]);
EOF
# The boot driver is untracked in the app checkout (local gate tooling) —
# the worktree at HEAD needs it, so the gate carries it as a fixture.
cp "$APP_ROOT/tool/oka_endless_driver.dart" "$WT/tool/oka_endless_driver.dart"

echo '== [2b] package resolution in the worktree (inside the adoption commit)'
FLUTTER_BIN=${FLUTTER_BIN:-$HOME/fvm/default/bin/flutter}
( cd "$WT" && "$FLUTTER_BIN" pub get > "$OUT/pubget.log" 2>&1 ) || {
  tail -5 "$OUT/pubget.log"; echo 'FAIL: pub get'; exit 1; }
git -C "$WT" add -A
git -C "$WT" -c user.name=gate -c user.email=gate@local \
  commit -qm 'oka ship: adopt patch units (air-channel gate)'
[ -z "$(git -C "$WT" status --porcelain)" ] || {
  git -C "$WT" status --porcelain | head -5; echo 'FAIL: dirty worktree'; exit 1; }

echo '== [3/7] the publisher signing key (ed25519; G-AC5)'
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$HERE/tool/oka_ship.dart" --generate-signing-key "$OUT/signing-key" ) \
  || { echo 'FAIL: keygen'; exit 1; }

echo '== [4/7] the arc: ship -> signed git branch -> client -> engine'
export AIR_WT="$WT" AIR_ORIGIN="$ORIGIN_BARE" AIR_OUT="$OUT" AIR_PORT="$PORT"
export AIR_SIGN_KEY="$OUT/signing-key"
export AIR_EDIT_FILE='packages/headless_core/lib/src/fractional_order.dart'
export AIR_EDIT_FIND='  return String.fromCharCodes([
    for (final digit in mid) _alphabet.codeUnitAt(digit),
  ]);'
export AIR_EDIT_REPLACE='  const patchedAlphabet = '"'"'acbdefghijklmnopqrstuvwxyz'"'"';
  return String.fromCharCodes([
    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),
  ]);'
export AIR_BOOT_ARGS='tool/oka_endless_driver.dart --serve'
export AIR_BOOT_MARKER='endless] boot'
export AIR_PROBE_LIBRARY='oka_endless_driver.dart'
export AIR_PROBE_CHANGE_EXPR='orderLabel()'
export AIR_PROBE_CHANGE_BEFORE='"b"'
export AIR_PROBE_CHANGE_WANT='"c"'
export AIR_PROBE_HOLD_EXPR='stateLabel()'
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$HERE/tool/air_channel_e2e.dart" ) 2>&1 | tee "$OUT/e2e.log"
STATUS=${PIPESTATUS[0]}

echo '== [5/7] the channel branch exists in the bare origin'
git -C "$ORIGIN_BARE" rev-parse --verify -q oka-channel >/dev/null || {
  echo 'FAIL: no oka-channel branch'; exit 1; }
git -C "$ORIGIN_BARE" cat-file blob oka-channel:pointer.json | grep -q '"signedBy"' || {
  echo 'FAIL: pointer is unsigned'; exit 1; }

echo '== [6/7] verdict'
tail -2 "$OUT/e2e.log"
[ "$STATUS" = "0" ] && grep -q "live patch OK" "$OUT/e2e.log"
