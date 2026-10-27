#!/usr/bin/env bash
# Every publishable package must mention the current VERSION in CHANGELOG.md
# (pub.dev validation treats a missing version as a warning; CI uses --dry-run).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
missing=()

while IFS= read -r package; do
  changelog="$ROOT_DIR/packages/$package/CHANGELOG.md"
  if [[ ! -f "$changelog" ]]; then
    missing+=("$package (no CHANGELOG.md)")
    continue
  fi
  if ! grep -qE "^## ${version}\$|^## \\[${version}\\]|^## ${version} |^## \\[${version}\\]" "$changelog"; then
    missing+=("$package")
  fi
done < <(dart "$ROOT_DIR/tool/release/train.dart" list)

if ((${#missing[@]} > 0)); then
  echo "check_package_changelogs: VERSION $version missing from:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "check_package_changelogs: all train packages mention $version"
