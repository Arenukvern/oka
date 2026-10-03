#!/usr/bin/env bash
# Linux (ELF) live-swap experiment for the deferred-units spike.
# Runs inside the official dart:3.13.2 container. Answers three questions:
#   Q1: does multi-unit AOT LOAD and run correctly on Linux (sdk#64162)?
#   Q2: does the VM verify unit-file bytes at loadLibrary() time?
#   Q3: can an UNLOADED unit be replaced on disk while the process runs,
#       such that the new code is picked up live (no restart)?
set -uo pipefail

SDK=/usr/lib/dart
GK=$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot
GS=$SDK/bin/utils/gen_snapshot
DR=$SDK/bin/dartaotruntime
cd /spike/spike || exit 1

# The driver/stress entries import nothing third-party, so we skip pub get
# (the container has no pub cache) and generate a minimal package config.
mkdir -p .dart_tool
cat > .dart_tool/package_config_container.json <<'EOF'
{
  "configVersion": 2,
  "packages": [
    {
      "name": "oka_patch_spike",
      "rootUri": "file:///spike/spike",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
EOF
PKGS=.dart_tool/package_config_container.json

build() { # $1 = outdir, $2 = entry
  "$DR" "$GK" \
    --platform="$SDK/lib/_internal/vm_platform_strong.dill" \
    --aot --packages="$PKGS" --target-os=linux \
    -o "$1/program.dill" "$2" || return 1
  "$GS" --snapshot-kind=app-aot-elf --elf="$1/units.so" \
    --loading_unit_manifest="$1/manifest.json" "$1/program.dill" || return 1
}

mkdir -p build_linux/v1 build_linux/v2 build_linux/stress /tmp/spike
rm -f /tmp/spike/go_swap

echo '=== Q0: build v1 (driver) + stress entry ==='
build build_linux/v1 tool/live_driver.dart || { echo 'v1 build failed'; exit 1; }
build build_linux/stress tool/aot_main.dart || { echo 'stress build failed'; exit 1; }
echo 'which unit is which part:'
grep -o '"libraries": \[[^]]*\]' build_linux/v1/manifest.json | tail -2
grep -o 'units.so-[0-9]*\.part\.so' build_linux/v1/manifest.json | sort -u

echo
echo '=== Q1: stock run of multi-unit AOT with #64162 stress ==='
"$DR" build_linux/stress/units.so
echo "Q1 exit: $?"

echo
echo '=== Q3 setup: beta v2 = LOGIC change on the LIVE code path (betaLabel wraps toUpperCase), then swap under a RUNNING v1 process ==='
sed -i "s|String betaLabel() => 'beta-v1 (stable unit)';|String betaLabel() => 'beta-v1 (stable unit)'.toUpperCase();|" lib/units/beta.dart
grep -q toUpperCase lib/units/beta.dart || { echo 'v2 sed did not apply; aborting'; exit 1; }
build build_linux/v2 tool/live_driver.dart || { echo 'v2 build failed'; exit 1; }
sed -i "s|String betaLabel() => 'beta-v1 (stable unit)'.toUpperCase();|String betaLabel() => 'beta-v1 (stable unit)';|" lib/units/beta.dart

# identify beta's part file from v1's manifest (root=units.so, alpha=-2, beta=-3 expected)
cat > /tmp/spike/extract_beta.dart <<'EOF'
import 'dart:convert';
import 'dart:io';
void main() {
  final m = jsonDecode(File('build_linux/v1/manifest.json').readAsStringSync());
  for (final u in m['loadingUnits']) {
    if ((u['libraries'] as List).any((l) => (l as String).contains('beta'))) {
      stdout.writeln((u['path'] as String).split('/').last);
    }
  }
}
EOF
BETA_PART=$("$SDK/bin/dart" /tmp/spike/extract_beta.dart)
echo "beta part file: $BETA_PART"
[ -n "$BETA_PART" ] || { echo 'could not identify beta part; aborting'; exit 1; }

echo '--- where do unit strings live? (v1; grep -a since binutils strings is absent) ---'
for f in build_linux/v1/units.so build_linux/v1/units.so-2.part.so build_linux/v1/units.so-3.part.so; do
  a=$(grep -ac 'alpha-v3' "$f" || true)
  b=$(grep -ac 'beta-v1' "$f" || true)
  echo "$f: alpha-v3=$a beta-v1=$b"
done

mkdir -p build_linux/live && cp build_linux/v1/units.so build_linux/v1/units.so-*.part.so build_linux/live/
rm -f build_linux/live_out.log
( "$DR" build_linux/live/units.so > build_linux/live_out.log 2>&1 & )

for i in $(seq 1 300); do
  grep -q 'waiting for marker' build_linux/live_out.log 2>/dev/null && break
  sleep 0.05
done
if ! grep -q 'waiting for marker' build_linux/live_out.log; then
  echo 'driver never reached marker; output so far:'; cat build_linux/live_out.log; exit 1
fi

echo "-- process is running and parked; swapping $BETA_PART with v2 bytes --"
cp "build_linux/v2/$BETA_PART" "build_linux/live/$BETA_PART"
sleep 0.5
touch /tmp/spike/go_swap
sleep 3
echo
echo '=== Q2/Q3 verdict: live output ==='
cat build_linux/live_out.log
echo
echo '=== root+unit hash table across v1/v2 (transfer-isolation reference) ==='
for f in units.so units.so-2.part.so units.so-3.part.so; do
  a=$(sha256sum "build_linux/v1/$f" | cut -c1-12)
  b=$(sha256sum "build_linux/v2/$f" | cut -c1-12)
  [ "$a" = "$b" ] && echo "SAME  $f" || echo "DIFF  $f ($a -> $b)"
done
