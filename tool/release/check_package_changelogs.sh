#!/usr/bin/env bash
# Every publishable package must mention the current VERSION in CHANGELOG.md
# (pub.dev validation treats a missing version as a warning; CI uses --dry-run).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
version_re="${version//./\\.}"
marker='x-release-please-version'
missing=()
follower_violations=()

while IFS= read -r package; do
  changelog="$ROOT_DIR/packages/$package/CHANGELOG.md"
  if [[ ! -f "$changelog" ]]; then
    missing+=("$package (no CHANGELOG.md)")
    continue
  fi
  if ! grep -qE "^## ${version_re}\$|^## \\[${version_re}\\]|^## ${version_re} |^## \\[${version_re}\\]" "$changelog"; then
    missing+=("$package")
  fi
  if [[ "$package" != "oka" ]]; then
    marker_count="$(grep -c "$marker" "$changelog" || true)"
    if [[ "$marker_count" -ne 1 ]]; then
      follower_violations+=("$package (expected exactly one $marker, found $marker_count)")
      continue
    fi
    frozen_marker_lines="$(grep -nE "^## [^#].*${marker}" "$changelog" | grep -vE "^[0-9]+:## ${version_re} " || true)"
    if [[ -n "$frozen_marker_lines" ]]; then
      follower_violations+=("$package (frozen section still carries $marker)")
    fi
    if ! grep -qE "^## ${version_re} .*${marker}|^## ${version_re} <!-- ${marker} -->" "$changelog"; then
      follower_violations+=("$package (current VERSION heading must carry $marker)")
    fi
  elif grep -q "$marker" "$changelog"; then
    follower_violations+=("oka (primary CHANGELOG must not use $marker)")
  fi
done < <(dart "$ROOT_DIR/tool/release/train.dart" list)

if ((${#missing[@]} > 0)); then
  echo "check_package_changelogs: VERSION $version missing from:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

if ((${#follower_violations[@]} > 0)); then
  echo "check_package_changelogs: follower heading / marker violations:" >&2
  printf '  - %s\n' "${follower_violations[@]}" >&2
  exit 1
fi

echo "check_package_changelogs: all train packages mention $version"
