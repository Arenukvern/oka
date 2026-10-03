#!/usr/bin/env bash
# Live-patch e2e across platforms (ADR-0031/0032/0034 P2): one declarative
# spec per leg, one session API (oka_update), one VM-service wire family.
#
# Legs (default: all):
#   mac-vm       stock dart VM on macOS, last_answer's headless driver,
#                unit doc_replica_store, `_reloadKernel` (host path)
#   linux-docker dart:3.13.2 (linux/amd64) container over same-path mounts,
#                same unit; delta pushed via LIVE_DELTA_DIR inside the app
#   android      flutter run on the emulator (arm64), unit fractional_order,
#                DevFS push (_createDevFS) + `_reloadKernel(device path)`
#   web          flutter run web-server + DDK in Chrome, unit fractional_order,
#                dwds reloadSources (oka-driven) + CDP page probes
#
# Every leg proves: patched value live BEFORE/AFTER flip, hold probe
# unchanged (no restart), receipt ok. Evidence lands in .gate_live_e2e/.
#
# Plain variables only: must run on macOS stock bash 3.2.
set -uo pipefail
# docker lives in /usr/local/bin on this Mac; keep the tool PATH minimal.
PATH="$PATH:/usr/local/bin"
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/.gate_live_e2e"
APP_ROOT=${APP_ROOT:-$HOME/xs/storage_problem/last_answer}
FLUTTER=${FLUTTER:-$HOME/fvm/default}
FDART="$FLUTTER/bin/cache/dart-sdk/bin/dart"
EMU=${ANDROID_EMULATOR:-$HOME/.oka/android-sdk/emulator/emulator}
ADB=${ADB:-$HOME/.oka/android-sdk/platform-tools/adb}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
STORE_LABEL='doc_replicas_live'
FRAC_OLD="const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';"
FRAC_NEW="const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';"

STORE_FILE="$APP_ROOT/packages/headless_core/lib/src/doc_replica_store.dart"
FRAC_FILE="$APP_ROOT/packages/headless_core/lib/src/fractional_order.dart"

mkdir -p "$OUT"
. "$HERE/tool/gate_lib.sh"

restore_markers() {
  restore_marker "$STORE_FILE" "doc_replicas_live" "doc_replicas"
  restore_marker "$FRAC_FILE" "acbdefghijklmnopqrstuvwxyz" "abcdefghijklmnopqrstuvwxyz"
}
cleanup() { restore_markers; }
trap cleanup EXIT

build_pkgs() { # $1 checkout, $2 lang-version, $3 out — cwd-safe wrapper
  ( cd "$HERE" && bash tool/pipeline_packages_config.sh "$1" "$2" "$3" )
}

# wait_for comes from gate_lib.sh (same signature: log pattern tries label).

delta_env() { # $1 dart, $2 packages-config, $3 sdk-hash, $4 target, $5 summary
  echo "LIVE_DELTA_DART=$1"
  echo "LIVE_DELTA_PACKAGES=$2"
  echo "LIVE_SDK_HASH=$3"
  echo "OKA_TARGET=$4"
  echo "DART_SDK_SUMMARY=$5"
  echo "DART_PACKAGES_CONFIG=$APP_ROOT/.dart_tool/package_config.json"
}

# AOT pipeline exe: identical output, ~7-11x faster than the JIT dart run.
# Built once per gate run; legs receive it via LIVE_PIPELINE_EXE.
PIPELINE_EXE="$OUT/pipeline.exe"
build_pipeline_exe() { # $1 checkout, $2 lang-version
  if [ ! -x "$PIPELINE_EXE" ]; then
    ( cd "$HERE" && bash tool/build_pipeline_exe.sh "$1" "$2" "$PIPELINE_EXE" ) \
      || PIPELINE_EXE=""
  fi
  [ -n "$PIPELINE_EXE" ] && echo "pipeline exe: $PIPELINE_EXE"
}

run_driver() { # $1 spec, $2 receipt, $3 log — remaining args: env K=V
  local spec=$1 receipt=$2 log=$3; shift 3
  ( cd "$HERE" && export LIVE_SPEC="$spec" LIVE_ROOT="$APP_ROOT" \
      LIVE_RECEIPT="$receipt" LIVE_DELTA_CWD="$HERE"; "$@" \
    dart tool/live_e2e.dart ) > "$log" 2>&1
}

# ---------------------------------------------------------------- mac-vm
leg_mac_vm() {
  echo "=== [live-e2e mac-vm] stock dart VM, unit doc_replica_store (Dart driver)"
  pkill -f "oka_kernel_driver.dart --serve" 2>/dev/null; sleep 1
  restore_markers
  local driver_log="$OUT/leg1.log"
  ( cd "$HERE/../.." && dart \
      --packages="$HERE/../../.dart_tool/package_config.json" \
      "$HERE/tool/live_e2e_mac_vm.dart" ) > "$driver_log" 2>&1
  local rc=$?
  tail -3 "$driver_log"
  [ $rc -eq 0 ] && grep -q "live patch OK" "$driver_log"
}

# ---------------------------------------------------------- linux-docker
leg_linux_docker() {
  echo "=== [live-e2e linux-docker] dart:3.13.2 container, same unit"
  restore_markers
  command -v docker >/dev/null 2>&1 || { echo "docker not found"; return 1; }
  local app_dart ver lang checkout hash pkgs spec receipt driver_log
  app_dart=$(dirname "$(readlink -f "$(command -v dart)")")/dart
  ver=$("$app_dart" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  lang=$(echo "$ver" | cut -d. -f1-2)
  checkout=${OKA_SDK_CHECKOUT:-$HOME/xs/dart-sdks/sdk-$ver}
  hash=$(git -C "$checkout" rev-parse --short=10 HEAD)
  pkgs=$(build_pkgs "$checkout" "$lang" "$OUT") || return 1
  build_pipeline_exe "$checkout" "$lang"
  spec="$OUT/spec_linux.json"; receipt="$OUT/receipt_linux.json"; driver_log="$OUT/leg2.log"
  docker rm -f oka-live-linux >/dev/null 2>&1
  docker run -d --name oka-live-linux -p 127.0.0.1:8185:8185 \
    -v "$APP_ROOT:$APP_ROOT" \
    -v "$HOME/xs/storage_problem/dart_flutter_packages:/Users/antonio/xs/storage_problem/dart_flutter_packages" \
    -v "$HOME/.pub-cache:/Users/antonio/.pub-cache" \
    -w "$APP_ROOT" dart:3.13.2 \
    dart --enable-vm-service=8185/0.0.0.0 --disable-service-auth-codes \
    tool/oka_kernel_driver.dart --serve >/dev/null || return 1
  sleep 8
  dart "$HERE/tool/live_e2e_spec.dart" linux "$spec" --app="$APP_ROOT" \
    --ws="ws://127.0.0.1:8185/ws" || return 1
  run_driver "$spec" "$receipt" "$driver_log" env \
    LIVE_DELTA_DIR="$APP_ROOT/.oka_live" \
    LIVE_PIPELINE_EXE="$PIPELINE_EXE" \
    LIVE_DELTA_DART="$app_dart" LIVE_DELTA_PACKAGES="$pkgs" LIVE_SDK_HASH="$hash" \
    OKA_TARGET=vm \
    DART_SDK_SUMMARY="$(dirname "$app_dart")/../lib/_internal/vm_platform_strong.dill" \
    DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json"
  local rc=$?
  docker rm -f oka-live-linux >/dev/null 2>&1
  rm -rf "$APP_ROOT/.oka_live"
  restore_markers
  [ $rc -eq 0 ] && grep -q "live patch OK" "$driver_log"
}

# ---------------------------------------------------------------- android
# The app's committed android config cannot build under this flutter
# (wrapper/AGP below the tool's floor; debug signing points at a
# TCC-protected iCloud keystore). The leg applies the two known-good build
# fixes and reverts them on exit — the app repo keeps its committed state.
ANDROID_PATCHED=""
android_patch_build() {
  cp "$APP_ROOT/android/gradle/wrapper/gradle-wrapper.properties" "$OUT/gradle-wrapper.properties.orig"
  cp "$APP_ROOT/android/settings.gradle.kts" "$OUT/settings.gradle.kts.orig"
  cp "$APP_ROOT/android/app/build.gradle.kts" "$OUT/app_build_gradle.kts.orig"
  sed -i '' 's/gradle-8.12-all.zip/gradle-8.14-all.zip/' \
    "$APP_ROOT/android/gradle/wrapper/gradle-wrapper.properties"
  sed -i '' 's/id("com.android.application") version "8.7.3" apply false/id("com.android.application") version "8.11.1" apply false/' \
    "$APP_ROOT/android/settings.gradle.kts"
  dart "$HERE/tool/live_e2e_spec.dart" patch-android-signing "$APP_ROOT" || return 1
  ANDROID_PATCHED=1
}
android_restore_build() {
  [ "$ANDROID_PATCHED" = 1 ] || return 0
  cp "$OUT/gradle-wrapper.properties.orig" "$APP_ROOT/android/gradle/wrapper/gradle-wrapper.properties"
  cp "$OUT/settings.gradle.kts.orig" "$APP_ROOT/android/settings.gradle.kts"
  cp "$OUT/app_build_gradle.kts.orig" "$APP_ROOT/android/app/build.gradle.kts"
  ANDROID_PATCHED=""
}

leg_android() {
  echo "=== [live-e2e android] flutter run on emulator, unit fractional_order"
  restore_markers
  android_patch_build
  export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-$HOME/.oka/android-sdk}
  export ANDROID_HOME=$ANDROID_SDK_ROOT
  pkill -f "flutter_tools.snapshot run -d emulator" 2>/dev/null; sleep 1
  # emulator up?
  "$ADB" devices 2>/dev/null | grep -q "emulator-.*device" || {
    nohup "$EMU" -avd oka-emulator -no-snapshot -no-audio -no-boot-anim \
      > /tmp/oka_gate_emulator.log 2>&1 &
    local i=0
    while [ $i -lt 30 ]; do
      [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
      sleep 10; i=$((i+1))
    done
  }
  "$ADB" devices | grep -q "emulator-.*device" || { echo "no emulator"; return 1; }
  local dev fl_log spec receipt driver_log ws http
  dev=$("$ADB" devices | grep "emulator-.*device" | head -1 | cut -f1)
  fl_log=/tmp/oka_gate_leg3_flutter.log; : > "$fl_log"
  ( cd "$APP_ROOT" && nohup "$FLUTTER/bin/flutter" run -d "$dev" --debug \
      --android-skip-build-dependency-validation \
      --pid-file="$OUT/flutter_android.pid" >> "$fl_log" 2>&1 & echo $! > "$OUT/leg3_flutter.pid" )
  wait_for "$fl_log" "A Dart VM Service" 150 "flutter android vm service" || {
    kill "$(cat "$OUT/leg3_flutter.pid")" 2>/dev/null; android_restore_build; return 1; }
  local uri
  uri=$(grep "A Dart VM Service" "$fl_log" | head -1 | grep -oE 'http://[^ ]+')
  ws=$(echo "$uri" | sed 's|http://|ws://|; s|/$||')/ws
  http="$uri"
  spec="$OUT/spec_android.json"; receipt="$OUT/receipt_android.json"; driver_log="$OUT/leg3.log"
  dart "$HERE/tool/live_e2e_spec.dart" android "$spec" --app="$APP_ROOT" \
    --ws="$ws" --http="$http" || return 1
  local checkout hash pkgs
  checkout=${OKA_SDK_CHECKOUT_FLUTTER:-$HOME/xs/dart-sdks/sdk-3.13.4}
  hash=$(git -C "$checkout" rev-parse --short=10 HEAD)
  pkgs="$OUT/pipeline_package_config_3134.json"
  [ -f "$pkgs" ] || pkgs=$(build_pkgs "$checkout" 3.13 "$OUT")
  run_driver "$spec" "$receipt" "$driver_log" env \
    LIVE_DELTA_DART="$FDART" LIVE_DELTA_PACKAGES="$pkgs" LIVE_SDK_HASH="$hash" \
    OKA_TARGET=flutter \
    DART_SDK_SUMMARY="$FLUTTER/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill" \
    DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json"
  local rc=$?
  kill "$(cat "$OUT/leg3_flutter.pid")" 2>/dev/null
  pkill -f "flutter_tools.snapshot run -d emulator" 2>/dev/null
  restore_markers
  [ $rc -eq 0 ] && grep -q "live patch OK" "$driver_log"
}

# -------------------------------------------------------------------- web
leg_web() {
  echo "=== [live-e2e web] flutter web-server + DDK in Chrome"
  restore_markers
  local fl_log spec receipt driver_log cdp_port
  fl_log=/tmp/oka_gate_leg4_flutter.log; : > "$fl_log"; cdp_port=9223
  pkill -f "flutter_tools.snapshot run -d web-server" 2>/dev/null
  pkill -f "oka-chrome-profile" 2>/dev/null
  rm -rf /tmp/oka-chrome-profile
  sleep 2
  ( cd "$APP_ROOT" && nohup "$FLUTTER/bin/flutter" run -d web-server \
      --web-hostname 127.0.0.1 --web-port 8187 \
      --pid-file="$OUT/flutter_web.pid" >> "$fl_log" 2>&1 & echo $! > "$OUT/leg4_flutter.pid" )
  wait_for "$fl_log" "is being served at" 80 "web server" || {
    kill "$(cat "$OUT/leg4_flutter.pid")" 2>/dev/null; return 1; }
  "$CHROME" --user-data-dir=/tmp/oka-chrome-profile \
    --remote-debugging-port=$cdp_port --no-first-run --no-default-browser-check \
    "http://127.0.0.1:8187" > /dev/null 2>&1 &
  wait_for "$fl_log" "A Dart VM Service" 120 "dwds debug service" || {
    pkill -f "oka-chrome-profile"; kill "$(cat "$OUT/leg4_flutter.pid")" 2>/dev/null; return 1; }
  local uri ws cdp_ws spec receipt driver_log
  uri=$(grep "A Dart VM Service" "$fl_log" | head -1 | grep -oE 'http://[^ ]+')
  ws=$(echo "$uri" | sed 's|http://|ws://|; s|/$||')/ws
  sleep 3
  cdp_ws=$(curl -s "http://127.0.0.1:$cdp_port/json/list" | python3 -c "
import json, sys
tabs = json.load(sys.stdin)
print(next(t['webSocketDebuggerUrl'] for t in tabs
           if t.get('title') == 'Last Answer' and t.get('type') == 'page'))") || {
    pkill -f "oka-chrome-profile"; kill "$(cat "$OUT/leg4_flutter.pid")" 2>/dev/null; return 1; }
  # clean baseline: the page must boot from the UNPATCHED bundle.
  local fpid; fpid=$(cat "$OUT/flutter_web.pid")
  kill -USR1 "$fpid" 2>/dev/null; sleep 10
  dart "$HERE/tool/cdp_eval.dart" "$cdp_ws" 'location.reload(true)' >/dev/null 2>&1
  sleep 15
  cdp_ws=$(curl -s "http://127.0.0.1:$cdp_port/json/list" | python3 -c "
import json, sys
tabs = json.load(sys.stdin)
print(next(t['webSocketDebuggerUrl'] for t in tabs
           if t.get('title') == 'Last Answer' and t.get('type') == 'page'))")
  # Baseline reset + assertion (dart helper: bash string handling proved
  # too fragile for this retry sequence).
  dart "$HERE/tool/web_reset.dart" "$cdp_port" b || {
    pkill -f "oka-chrome-profile"; kill "$(cat "$OUT/leg4_flutter.pid")" 2>/dev/null; return 1; }

  spec="$OUT/spec_web.json"; receipt="$OUT/receipt_web.json"; driver_log="$OUT/leg4.log"
  dart "$HERE/tool/live_e2e_spec.dart" web "$spec" --app="$APP_ROOT" \
    --ws="$ws" --pid-file="$OUT/flutter_web.pid" --cdp="$cdp_ws" || return 1
  local checkout hash pkgs
  checkout=${OKA_SDK_CHECKOUT_FLUTTER:-$HOME/xs/dart-sdks/sdk-3.13.4}
  hash=$(git -C "$checkout" rev-parse --short=10 HEAD)
  pkgs="$OUT/pipeline_package_config_3134.json"
  [ -f "$pkgs" ] || pkgs=$(build_pkgs "$checkout" 3.13 "$OUT")
  run_driver "$spec" "$receipt" "$driver_log" env \
    LIVE_DELTA_DART="$FDART" LIVE_DELTA_PACKAGES="$pkgs" LIVE_SDK_HASH="$hash" \
    OKA_TARGET=flutter \
    DART_SDK_SUMMARY="$FLUTTER/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill" \
    DART_PACKAGES_CONFIG="$APP_ROOT/.dart_tool/package_config.json"
  local rc=$?
  pkill -f "oka-chrome-profile" 2>/dev/null
  kill "$(cat "$OUT/leg4_flutter.pid")" 2>/dev/null
  pkill -f "flutter_tools.snapshot run -d web-server" 2>/dev/null
  restore_markers
  [ $rc -eq 0 ] && grep -q "live patch OK" "$driver_log"
}

# ----------------------------------------------------------------- runner
LEGS=${1:-all}
R_MACVM=SKIP; R_LINUX=SKIP; R_ANDROID=SKIP; R_WEB=SKIP

if [ "$LEGS" = all ] || [ "$LEGS" = mac-vm ]; then
  leg_mac_vm && R_MACVM=PASS || R_MACVM=FAIL
fi
if [ "$LEGS" = all ] || [ "$LEGS" = linux-docker ]; then
  leg_linux_docker && R_LINUX=PASS || R_LINUX=FAIL
fi
if [ "$LEGS" = all ] || [ "$LEGS" = android ]; then
  leg_android && R_ANDROID=PASS || R_ANDROID=FAIL
fi
if [ "$LEGS" = all ] || [ "$LEGS" = web ]; then
  leg_web && R_WEB=PASS || R_WEB=FAIL
fi

echo
echo "==================== live-e2e SUMMARY ===================="
echo "mac-vm:       $R_MACVM"
echo "linux-docker: $R_LINUX"
echo "android:      $R_ANDROID"
echo "web:          $R_WEB"
[ "$R_MACVM" != FAIL ] && [ "$R_LINUX" != FAIL ] \
  && [ "$R_ANDROID" != FAIL ] && [ "$R_WEB" != FAIL ]
