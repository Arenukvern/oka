#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
missing=()

while IFS= read -r package; do
  if [[ ! -f "$ROOT_DIR/packages/$package/LICENSE" ]]; then
    missing+=("$package")
  fi
done < <(dart "$ROOT_DIR/tool/release/train.dart" list)

if ((${#missing[@]} > 0)); then
  echo "check_package_licenses: missing packages/$package/LICENSE for:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "check_package_licenses: all train packages have LICENSE"
