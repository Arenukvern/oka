#!/usr/bin/env bash
# Validate and publish the complete oka package train in dependency order.
#
# Usage: tool/release/publish_packages.sh [--dry-run|--publish]
set -euo pipefail

ROOT_DIR="${OKA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
mode="dry-run"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --dry-run) mode="dry-run" ;;
    --publish) mode="publish" ;;
    -h|--help) echo "Usage: tool/release/publish_packages.sh [--dry-run|--publish]"; exit 0 ;;
    *) echo "publish_packages: unknown argument: $1" >&2; exit 2 ;;
  esac
fi
[[ $# -le 1 ]] || { echo "publish_packages: too many arguments" >&2; exit 2; }

cd "$ROOT_DIR"
bash tool/release/check_version_sync.sh

# Dependencies first: core → conformance/android → platform targets → CLI.
package_list="$(dart tool/release/train.dart list)"
packages=()
while IFS= read -r package; do packages+=("$package"); done <<< "$package_list"
version="$(tr -d '[:space:]' < VERSION)"
wait_seconds="${OKA_PUB_PROPAGATION_WAIT_SECONDS:-10}"
wait_timeout="${OKA_PUB_PROPAGATION_TIMEOUT_SECONDS:-120}"
[[ "$wait_seconds" =~ ^[1-9][0-9]*$ && "$wait_timeout" =~ ^[1-9][0-9]*$ ]] || {
  echo "publish_packages: propagation intervals must be positive integers" >&2
  exit 2
}

published_version() {
  curl --fail --silent --show-error --max-time 10 \
    "https://pub.dev/api/packages/$1/versions/$version" >/dev/null 2>&1
}

wait_for_hosted_version() {
  local package="$1" elapsed=0
  while ! published_version "$package"; do
    (( elapsed >= wait_timeout )) && {
      echo "publish_packages: timed out waiting for $package $version on pub.dev" >&2
      return 1
    }
    sleep "$wait_seconds"
    elapsed=$((elapsed + wait_seconds))
  done
}

for package in "${packages[@]}"; do
  echo "publish_packages: $mode $package"
  if [[ "$mode" == "publish" ]]; then
    if published_version "$package"; then
      echo "publish_packages: $package $version already exists; skipping"
    else
      (cd "packages/$package" && dart pub publish --force)
      wait_for_hosted_version "$package"
    fi
  else
    (cd "packages/$package" && dart pub publish --dry-run)
  fi
done
