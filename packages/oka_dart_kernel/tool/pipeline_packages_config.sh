#!/usr/bin/env bash
# Builds the merged package_config the checkout kernel-stack tools run
# under: kernel/vm/front_end (+ their deps) mapped into the pinned SDK
# checkout (checkout-wins on dedupe), everything else pub-solved through a
# depshim. Shared by the real-app gates (G2.5-real-B, G3-real-B).
#
# Usage: tool/pipeline_packages_config.sh <SDK_CHECKOUT> <LANG_VERSION> <OUT_DIR>
# Prints the merged config path.
set -euo pipefail

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECKOUT=$1
LANG_VERSION=$2
OUT_DIR=$3
mkdir -p "$OUT_DIR"

deps=$(for p in kernel vm front_end; do
  awk '/^dependencies:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_]+:/{print $1}' \
    "$CHECKOUT/pkg/$p/pubspec.yaml" | tr -d ':'
done | sort -u)
pub_deps=""
checkout_entries=""
for d in $deps; do
  case "$d" in kernel|vm|front_end) continue ;; esac
  if [ -d "$CHECKOUT/pkg/$d/lib" ]; then
    checkout_entries+=$'\n  {"name": "'"$d"'", "rootUri": "file://'"$CHECKOUT"'/pkg/'"$d"'", "packageUri": "lib/", "languageVersion": "'"$LANG_VERSION"'"},'
  else
    pub_deps+="$d "
  fi
done
mkdir -p "$OUT_DIR/depshim"
{
  echo 'name: depshim'
  echo 'publish_to: none'
  echo 'environment:'
  echo '  sdk: ^3.13.0'
  echo 'dependencies:'
  for d in $pub_deps; do echo "  $d: any"; done
} > "$OUT_DIR/depshim/pubspec.yaml"
(cd "$OUT_DIR/depshim" && dart pub get >/dev/null 2>&1) || {
  echo 'shim pub get failed'
  exit 1
}
cat > "$OUT_DIR/extra_entries.json" <<JSONEOF
[
  {"name": "kernel", "rootUri": "file://$CHECKOUT/pkg/kernel", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},
  {"name": "vm", "rootUri": "file://$CHECKOUT/pkg/vm", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},
  {"name": "front_end", "rootUri": "file://$CHECKOUT/pkg/front_end", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"},$checkout_entries
  {"name": "oka_dart_kernel", "rootUri": "file://$PKG_DIR", "packageUri": "lib/", "languageVersion": "$LANG_VERSION"}
]
JSONEOF
dart tool/merge_package_config.dart \
  "$OUT_DIR/depshim/.dart_tool/package_config.json" \
  "$OUT_DIR/pipeline_package_config.json" \
  "$OUT_DIR/extra_entries.json"

echo "$OUT_DIR/pipeline_package_config.json"
