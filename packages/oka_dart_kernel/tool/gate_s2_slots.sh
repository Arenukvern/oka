#!/usr/bin/env bash
# S2 slot-swap end-to-end (lane S2, ADR-0035 §S2): the GENERATOR emits the
# revision-suffixed slot registry (no hand-written revision binding), a
# fully AOT program boots through it, and oka_update's embedded runtime
# applies a SIGNED slot-update envelope in-process — load r2, flip the
# registry pointer, receipt — with the negatives refusing by name
# (tampered signature, unprovisioned revision, replay already-current) and
# a [record]-only probe of the open empirical question (whether the VM's
# deferred loader maps a re-compiled part ELF staged over the provisioned
# slot file). Same physical bounds as gate_aot_slots.sh: slots are
# pre-provisioned at build time and bounded per process; unbounded
# revisions stay S3's snapshot handoff / the sdk#64162 research lane.
#
# Compile lane: the host SDK's own gen_kernel AOT frontend (the
# gen_kernel_dill.sh recipe — deferred imports intact), so the gate runs
# on any machine with a plain dart; no SDK source checkout needed.
#
# Steps: app + provision spec -> generated registry + runtime-embedding
# main -> gen_kernel dill -> gen_snapshot ELF + loading-unit manifest
# (>= 2 parts) -> ed25519 publisher keys -> boot AOT -> v1 -> signed
# envelope -> v2 SAME PID + receipts -> negatives -> [record] part-file
# swap probe.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_s2_slots"
ROOT=$(cd "$HERE/../.." && pwd)
WS_CONFIG="$ROOT/.dart_tool/package_config.json"
SDK=${DART_SDK_ROOT:-$(dirname "$(dirname "$(readlink -f "$(command -v dart)")")")}
# SDK layout probe: plain dart-sdk (bin/dart, lib/) vs nested (fvm/homebrew:
# bin/dart -> bin/cache/dart-sdk).
if [ ! -f "$SDK/lib/_internal/vm_platform_strong.dill" ]; then
  SDK="$SDK/bin/cache/dart-sdk"
fi
[ -f "$SDK/lib/_internal/vm_platform_strong.dill" ] || \
  { echo "no dart SDK with vm_platform_strong.dill under $SDK"; exit 1; }
HOST_DART=$(command -v dart)
GEN_KERNEL="$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot"
GEN_SNAPSHOT="$SDK/bin/utils/gen_snapshot"
DARTAOTRUNTIME="$SDK/bin/dartaotruntime"
[ -f "$WS_CONFIG" ] || { echo "workspace package config missing: $WS_CONFIG (run dart pub get at $ROOT)"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/app/lib/units"

wait_for() { # wait_for <grep-pattern> <log> [iterations=60]
  for _ in $(seq 1 "${3:-60}"); do
    grep -q "$1" "$2" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

receipt_of() { # receipt_of <envelope-name> -> prints the receipt file once present
  local f="$OUT/.slot-updates/$1.receipt.json"
  for _ in $(seq 1 60); do
    [ -f "$f" ] && { echo "$f"; return 0; }
    sleep 0.5
  done
  return 1
}

compile_app() { # compile_app <app-dir> <out-dill>
  "$SDK/bin/dartaotruntime" "$GEN_KERNEL" \
    --platform="$SDK/lib/_internal/vm_platform_strong.dill" \
    --aot --packages="$1/.dart_tool/package_config.json" \
    --target-os=macos -o "$2" "$1/lib/main.dart"
  echo "dill: $2"
}

snapshot_app() { # snapshot_app <dill> <elf-path> <manifest-path>
  "$GEN_SNAPSHOT" \
    --snapshot-kind=app-aot-elf \
    --elf="$2" \
    --loading_unit_manifest="$3" \
    "$1"
}

echo '== [aot-s2 1/7] the app: revision slot libraries + provision spec'
cat > "$OUT/app/pubspec.yaml" <<'EOF'
name: aot_s2_slots
publish_to: none
environment:
  sdk: ^3.12.0
EOF
cat > "$OUT/app/lib/units/feature_r1.dart" <<'EOF'
String feature() => 'aot-v1';
EOF
cat > "$OUT/app/lib/units/feature_r2.dart" <<'EOF'
String feature() => 'aot-v2-live';
EOF
cat > "$OUT/provision.json" <<'EOF'
{"families": [{"name": "feature", "contractType": "String Function()",
  "revisions": [
    {"id": "r1", "importUri": "units/feature_r1.dart", "member": "feature"},
    {"id": "r2", "importUri": "units/feature_r2.dart", "member": "feature"}]}]}
EOF

echo '== [aot-s2 2/7] the GENERATOR emits the registry; main embeds oka_update runtime'
(cd "$HERE" && "$HOST_DART" run tool/emit_slot_registry.dart \
  --spec "$OUT/provision.json" --out "$OUT/app/lib/oka_slots.g.dart") | tail -1
grep -q 'featureUnit' "$OUT/app/lib/oka_slots.g.dart"
cat > "$OUT/app/lib/main.dart" <<'EOF'
import 'dart:async';
import 'dart:io';

import 'oka_slots.g.dart';
import 'package:oka_update/oka_update.dart';

Future<void> main() async {
  await loadFeatureSlot('r1');
  // ignore: avoid_print
  print('aot: ${featureUnit()} pid=$pid');
  final runtime = SlotRuntime(
    spec: SlotRuntimeSpec(
      families: {
        'feature': SlotFamilyRuntime(
          revisions: {...featureSlotRevisions},
          load: loadFeatureSlot,
          currentRevision: () => featureRevision,
        ),
      },
      trustedPublicKeyHex: File('trust.pub').readAsStringSync().trim(),
    ),
  );
  unawaited(runtime.watchDirectory('.slot-updates',
      pollInterval: const Duration(milliseconds: 100),
      onReceipt: (receipt) {
        // ignore: avoid_print
        print('slot-receipt: mode=${receipt.mode} family=${receipt.family} '
            'from=${receipt.from} to=${receipt.to} '
            'refusal=${receipt.refusalCode}');
        if (receipt.mode == 'slot-swap') {
          // ignore: avoid_print
          print('aot: ${featureUnit()} pid=$pid');
        }
      }));
  await Completer<void>().future; // serve until killed
}
EOF
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_appconfig.dart \
  --app-root "$OUT/app" --workspace-config "$WS_CONFIG" \
  --out "$OUT/app/.dart_tool/package_config.json") | tail -1

echo '== [aot-s2 3/7] gen_kernel dill (deferred imports intact) -> gen_snapshot ELF + manifest'
compile_app "$OUT/app" "$OUT/app.dill" 2>&1 | tail -1
snapshot_app "$OUT/app.dill" "$OUT/base.so" "$OUT/manifest.json"
PARTS=$(grep -c '"path"' "$OUT/manifest.json" || true)
echo "loading units in manifest: $PARTS (need >= 2: base + revision slots)"
[ "$PARTS" -ge 2 ]

echo '== [aot-s2 4/7] publisher keys (ed25519 anchor -> trust.pub)'
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart keys \
  --keys-dir "$OUT/keys") | tail -1
cp "$OUT/keys/public.hex" "$OUT/trust.pub"

echo '== [aot-s2 5/7] boot the AOT program — v1 through the GENERATED registry'
( cd "$OUT" && "$DARTAOTRUNTIME" base.so > "$OUT/run.log" 2>&1 &
  echo $! > "$OUT/run.pid" )
wait_for "aot: aot-v1" "$OUT/run.log"
head -1 "$OUT/run.log"

echo '== [aot-s2 6/7] signed envelope -> in-process slot-swap (same pid) + negatives'
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart sign \
  --seed-file "$OUT/keys/seed.hex" --dir "$OUT/.slot-updates" \
  --family feature --revision r2) | tail -1
wait_for "aot: aot-v2-live" "$OUT/run.log"
grep "aot:" "$OUT/run.log"
grep -q '"mode":"slot-swap"' "$(receipt_of slot-update-feature-r2.json)"
grep -q '"from":"r1"' "$OUT/.slot-updates/slot-update-feature-r2.json.receipt.json"
grep -q '"to":"r2"' "$OUT/.slot-updates/slot-update-feature-r2.json.receipt.json"

# Negative 1: a tampered payload refuses by signature — the program does
# not change.
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart sign \
  --seed-file "$OUT/keys/seed.hex" --dir "$OUT/.slot-updates" \
  --family feature --revision r2 --filename env-tamper-src.json) > /dev/null
sed 's/"stable"/"stab1e"/' "$OUT/.slot-updates/env-tamper-src.json" \
  > "$OUT/.slot-updates/env-tampered.json"
wait_for 'refusal=slot_envelope_signature_invalid' "$OUT/run.log"
# Negative 2: an unprovisioned revision refuses by name.
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart sign \
  --seed-file "$OUT/keys/seed.hex" --dir "$OUT/.slot-updates" \
  --family feature --revision r9 --filename env-r9.json) > /dev/null
wait_for 'refusal=slot_revision_unknown' "$OUT/run.log"
# Negative 3: a replay receipts already-current (no re-load).
(cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart sign \
  --seed-file "$OUT/keys/seed.hex" --dir "$OUT/.slot-updates" \
  --family feature --revision r2) > /dev/null
wait_for 'mode=already-current' "$OUT/run.log"
grep 'slot-receipt:' "$OUT/run.log"
[ "$(grep -c 'pid=' "$OUT/run.log")" = "2" ] && \
  [ "$(grep -o 'pid=[0-9]*' "$OUT/run.log" | sort -u | wc -l | tr -d ' ')" = "1" ]
kill "$(cat "$OUT/run.pid")" 2>/dev/null || true

echo '== [aot-s2 7/7] [record] staged part-ELF swap probe (non-failing, empirical)'
# The open question ADR-0035 Part 2d leaves open: does the VM deferred
# loader map a RE-COMPILED part ELF staged over the provisioned slot file
# (before its first in-process load)? One changed unit body, same program
# structure, fresh boot. This step RECORDS the observation; it never
# gates.
VARIANT="$OUT/variant"
RECORD="$OUT/record"
mkdir -p "$VARIANT/app/lib/units" "$VARIANT/app/.dart_tool" "$RECORD/.slot-updates"
cat > "$VARIANT/app/lib/units/feature_r2.dart" <<'EOF'
String feature() => 'aot-v2-swapped-file';
EOF
cp "$OUT/app/lib/units/feature_r1.dart" "$VARIANT/app/lib/units/"
cp "$OUT/app/lib/oka_slots.g.dart" "$VARIANT/app/lib/"
cp "$OUT/app/lib/main.dart" "$VARIANT/app/lib/"
cp "$OUT/app/.dart_tool/package_config.json" "$VARIANT/app/.dart_tool/"
compile_app "$VARIANT/app" "$VARIANT/app.dill" 2>&1 | tail -1
snapshot_app "$VARIANT/app.dill" "$VARIANT/base.so" "$VARIANT/manifest.json"
# Fresh program tree: base bytes, VARIANT part bytes staged over them
# (part files sit next to the ELF as `<elf>-<n>.part.so`).
cp "$OUT/base.so" "$OUT/manifest.json" "$OUT/trust.pub" "$RECORD/"
STAGED=none
for part in "$OUT"/base.so-*.part.so; do
  [ -e "$part" ] || continue
  name=$(basename "$part")
  variant_part="$VARIANT/$name"
  if [ -e "$variant_part" ] && [ "$(shasum -a 256 "$part" | cut -d' ' -f1)" != \
      "$(shasum -a 256 "$variant_part" | cut -d' ' -f1)" ]; then
    echo "[record] part differs (changed unit candidate): $name"
    cp "$variant_part" "$RECORD/$name"
    STAGED="$name"
  else
    cp "$part" "$RECORD/$name" 2>/dev/null || true
  fi
done
echo "[record] staged changed part: $STAGED"
( cd "$RECORD" && "$DARTAOTRUNTIME" base.so > "$RECORD/run.log" 2>&1 &
  echo $! > "$RECORD/run.pid" )
if wait_for "aot: aot-v1" "$RECORD/run.log" 40; then
  (cd "$HERE" && "$HOST_DART" run tool/s2_gate_publish.dart sign \
    --seed-file "$OUT/keys/seed.hex" --dir "$RECORD/.slot-updates" \
    --family feature --revision r2) > /dev/null
  if wait_for 'aot-v2-swapped-file' "$RECORD/run.log" 40; then
    echo '[record] RESULT: the loader MAPPED the swapped part — staged '
    echo '[record] part-ELF OTA loads in-process (file-delivered AOT update).'
  elif wait_for 'aot-v2-live' "$RECORD/run.log" 40; then
    echo '[record] RESULT: the loader did NOT map the swapped part '
    echo '[record] (served the provisioned bytes).'
  else
    echo '[record] RESULT: the program refused or died loading the '
    echo '[record] swapped part; log follows.'
    tail -5 "$RECORD/run.log" || true
  fi
else
  echo '[record] RESULT: boot refused the swapped part layout; log follows.'
  tail -5 "$RECORD/run.log" || true
fi
kill "$(cat "$RECORD/run.pid")" 2>/dev/null || true

echo '== gate_s2_slots: PASS (the [record] line above is an observation, not a claim)'
