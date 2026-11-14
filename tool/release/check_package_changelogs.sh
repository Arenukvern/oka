#!/usr/bin/env bash
# Every publishable package must mention the current VERSION in CHANGELOG.md
# (pub.dev validation treats a missing version as a warning; CI uses --dry-run).
# Bash 3.2 compatible — semver compare via tool/release/semver_tool.dart.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
version_re="${version//./\\.}"
marker='x-release-please-version'
semver_heading='^## (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
missing=()
follower_violations=()

semver_cmp() {
  dart "$ROOT_DIR/tool/release/semver_tool.dart" cmp "$1" "$2"
}

heading_version() {
  sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' <<<"$1"
}

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
    first_numbered="$(grep -nE "$semver_heading" "$changelog" | head -1 || true)"
    if [[ -z "$first_numbered" ]]; then
      follower_violations+=("$package (no semver version heading)")
      continue
    fi
    first_version_line="${first_numbered#*:}"
    first_line_num="${first_numbered%%:*}"
    if [[ "$first_version_line" != *"$marker"* ]]; then
      follower_violations+=("$package (first version heading must carry $marker)")
      continue
    fi
    marked_version="$(heading_version "$first_version_line")"
    if [[ -z "$marked_version" ]]; then
      follower_violations+=("$package (could not parse marked heading version)")
      continue
    fi
    if [[ "$(semver_cmp "$marked_version" "$version")" -lt 0 ]]; then
      follower_violations+=("$package (marked heading $marked_version is below VERSION $version)")
    fi
    while IFS= read -r numbered; do
      [[ -z "$numbered" ]] && continue
      line_no="${numbered%%:*}"
      line_body="${numbered#*:}"
      if [[ "$line_no" == "$first_line_num" ]]; then
        continue
      fi
      if [[ "$line_body" == *"$marker"* ]]; then
        follower_violations+=("$package (frozen section still carries $marker)")
        break
      fi
    done < <(grep -nE "$semver_heading" "$changelog" || true)
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