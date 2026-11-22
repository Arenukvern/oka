#!/usr/bin/env bash
# Every publishable package must mention the current VERSION in CHANGELOG.md
# (pub.dev validation treats a missing version as a warning; CI uses --dry-run).
# The release-please marker law is retired (ADR-0054): dart_changesets
# requires BARE `## X.Y.Z` headings, and versions move via changeset
# intents now, not the marker.
# Bash 3.2 compatible — semver compare via tool/release/semver_tool.dart.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
version_re="${version//./\\.}"
semver_heading='^## (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
missing=()

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
done < <(dart "$ROOT_DIR/tool/release/train.dart" list)

if ((${#missing[@]} > 0)); then
  echo "check_package_changelogs: VERSION $version missing from:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi


echo "check_package_changelogs: all train packages mention $version"
