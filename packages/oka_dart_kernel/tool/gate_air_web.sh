#!/usr/bin/env bash
# Air channel — web verify rung (ADR-0037 G-AC7): the invisible ship
# generates the channel from last_answer's working tree (units declared
# once in the app's tool/patch_units.dart), a real `flutter build web
# --release` + the channel are materialized on a dumb static host, and an
# UpdateClient proves the ADR-0031 gates 2–4 semantics over plain HTTP:
# changed-artifacts-only transfer, contract-refusal at plan time, and a
# rollback repoint that moves no payloads.
#
# Usage: tool/gate_air_web.sh   (env: LIVE_APP_ROOT, OKA_SDK_CHECKOUT,
#                                FLUTTER_BIN)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_air_web"
APP_ROOT=${LIVE_APP_ROOT:-$HOME/xs/storage_problem/last_answer}
APP_PARENT=$(dirname "$APP_ROOT")
WT="$APP_PARENT/.oka-air-web-wt"
WS=$(cd "$HERE/../.." && pwd)
PORT=${AIR_SERVE_PORT:-8744}
. "$HERE/tool/gate_lib.sh"
mkdir -p "$OUT"
FLUTTER_BIN=${FLUTTER_BIN:-$HOME/fvm/default/bin/flutter}

cleanup() {
  git -C "$APP_ROOT" worktree remove --force "$WT" 2>/dev/null || true
}
trap cleanup EXIT

echo '== [1/4] last_answer worktree at HEAD (same depth so sibling deps resolve)'
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$APP_ROOT" worktree remove --force "$WT" 2>/dev/null || true
git -C "$APP_ROOT" worktree add --detach "$WT" HEAD >/dev/null || {
  echo 'FAIL: worktree add'; exit 1; }
# last_answer does not commit its pubspec.lock — resolution state lives
# only in the checkout. Carry it over so the worktree resolves exactly
# like the app the developer actually runs (a fresh resolve can drift to
# newer majors whose APIs differ — e.g. file_picker 12's web shape).
[ -f "$APP_ROOT/pubspec.lock" ] && cp "$APP_ROOT/pubspec.lock" "$WT/pubspec.lock"

echo '== [2/4] the adoption: the APP declares its units once'
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
( cd "$WT" && "$FLUTTER_BIN" pub get > "$OUT/pubget.log" 2>&1 ) || {
  tail -5 "$OUT/pubget.log"; echo 'FAIL: pub get'; exit 1; }
git -C "$WT" add -A
git -C "$WT" -c user.name=gate -c user.email=gate@local \
  commit -qm 'oka ship: adopt patch units (air-channel web gate)'
[ -z "$(git -C "$WT" status --porcelain)" ] || {
  git -C "$WT" status --porcelain | head -5; echo 'FAIL: dirty worktree'; exit 1; }

echo '== [3/4] the arc: ship -> release web build -> static host -> HTTP client'
export AIR_APP="$WT" AIR_OUT="$OUT" AIR_SERVE_PORT="$PORT"
export AIR_FLUTTER="$FLUTTER_BIN"
( cd "$WS" && dart --packages="$WS/.dart_tool/package_config.json" \
    "$HERE/tool/air_channel_web.dart" ) 2>&1 | tee "$OUT/arc.log"
STATUS=${PIPESTATUS[0]}

echo '== [4/4] verdict'
tail -2 "$OUT/arc.log"
[ "$STATUS" = "0" ] && grep -q "air-channel web: OK" "$OUT/arc.log"
