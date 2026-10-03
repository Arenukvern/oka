#!/usr/bin/env bash
# AOT slot prototype (lane S2, ADR-0035): "100% AOT live patching" within
# the physically possible — a fully AOT program (dartaotruntime + ELF)
# flips a unit's revision IN-PROCESS by deferred-loading a pre-provisioned
# revision slot (feature_r1 -> feature_r2). No restart, no VM service, no
# kernel reload into AOT (impossible without an SDK fork — banned); an
# unbounded revision stream is S3's snapshot handoff (proven on linux).
#
# Steps: compile dill (oka pipeline) -> gen_snapshot ELF + loading-unit
# manifest (must split >= 2 parts) -> run under dartaotruntime -> v1 ->
# drop the update signal -> v2, same process.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_aot_slots"
CHECKOUT=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-3.13.2}
# gen_snapshot + dartaotruntime come from the HOST dart (same version as
# the checkout that builds the dill) — the gate_aot_platforms recipe.
HOST_SDK=$(dirname "$(dirname "$(readlink -f "$(command -v dart)")")")
HOST_DART=$(command -v dart)
VERSION=$(basename "$CHECKOUT" | sed 's/^sdk-//')
LANG=$(echo "$VERSION" | cut -d. -f1-2)
HASH=$(git -C "$CHECKOUT" rev-parse --short=10 HEAD)
rm -rf "$OUT"; mkdir -p "$OUT/app/lib/units"

echo '== [aot-slots 1/5] the app: boot loads r1; a signal file loads r2 — in-process'
cat > "$OUT/app/pubspec.yaml" <<'EOF'
name: aot_slots
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
mkdir -p "$OUT/app/.dart_tool"
cat > "$OUT/app/.dart_tool/package_config.json" <<PKGEOF
{
  "configVersion": 2,
  "packages": [
    {"name": "aot_slots", "rootUri": "file://$OUT/app", "packageUri": "lib/", "languageVersion": "3.12"}
  ]
}
PKGEOF
cat > "$OUT/app/lib/main.dart" <<'EOF'
import 'dart:io';
import 'units/feature_r1.dart' deferred as r1;
import 'units/feature_r2.dart' deferred as r2;

Future<void> main() async {
  await r1.loadLibrary();
  // ignore: avoid_print
  print('aot: ${r1.feature()} pid=$pid');
  final signal = File('update.signal');
  while (!signal.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  await r2.loadLibrary(); // the revision slot, loaded from disk in-process
  // ignore: avoid_print
  print('aot: ${r2.feature()} pid=$pid');
}
EOF
mkdir -p "$OUT/app/.dart_tool"

echo '== [aot-slots 2/5] compile the dill (oka pipeline)'
PACKAGES=$( ( cd "$HERE" && bash tool/pipeline_packages_config.sh "$CHECKOUT" "$LANG" "$OUT" ) | tail -1 )
DART_SDK_SUMMARY="$HOST_SDK/lib/_internal/vm_platform_strong.dill" \
DART_PACKAGES_CONFIG="$OUT/app/.dart_tool/package_config.json" \
OKA_TARGET=vm \
  "$HOST_SDK/bin/dart" -Dsdk_hash=$HASH --packages="$PACKAGES" \
  "$HERE/tool/gate_pipeline.dart" "$OUT/app/lib/main.dart" "$OUT/app.dill" \
  2>&1 | tail -1

echo '== [aot-slots 3/5] gen_snapshot: ELF + loading-unit manifest'
"$HOST_SDK/bin/utils/gen_snapshot" \
  --snapshot-kind=app-aot-elf \
  --elf="$OUT/base.so" \
  --loading_unit_manifest="$OUT/manifest.json" \
  "$OUT/app.dill"
PARTS=$(grep -c '"path"' "$OUT/manifest.json" || true)
echo "loading units in manifest: $PARTS (need >= 2: base + revision slots)"

echo '== [aot-slots 4/5] run the AOT program (v1 expected)'
( cd "$OUT" && "$HOST_SDK/bin/dartaotruntime" base.so > "$OUT/run.log" 2>&1 &
  echo $! > "$OUT/run.pid" )
for _ in $(seq 1 40); do
  grep -q "aot: aot-v1" "$OUT/run.log" 2>/dev/null && break
  sleep 0.5
done
head -1 "$OUT/run.log"
grep -q "aot: aot-v1" "$OUT/run.log" || { echo 'v1 never printed'; exit 1; }

echo '== [aot-slots 5/5] live: load revision slot r2 — same process (AOT)'
touch "$OUT/update.signal"
for _ in $(seq 1 40); do
  grep -q "aot: aot-v2-live" "$OUT/run.log" 2>/dev/null && break
  sleep 0.5
done
grep "aot:" "$OUT/run.log"
kill "$(cat "$OUT/run.pid")" 2>/dev/null || true
grep -q "aot: aot-v2-live" "$OUT/run.log" && \
  [ "$(grep -c 'pid=' "$OUT/run.log")" = "2" ] && \
  [ "$(grep -o 'pid=[0-9]*' "$OUT/run.log" | sort -u | wc -l)" = "1" ]
