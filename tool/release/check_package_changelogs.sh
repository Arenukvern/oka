#!/usr/bin/env bash
# Train packages must document VERSION for pub.dev; release-please only updates
# packages/oka/CHANGELOG.md. Packages with <!-- oka-train-changelog: ... --> may
# keep the canonical release notes in the oka changelog once they have shipped at
# least one train version locally (see packages/*/CHANGELOG.md ## 0.9.0).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
train_marker='oka-train-changelog: packages/oka/CHANGELOG.md'
oka_changelog="$ROOT_DIR/packages/oka/CHANGELOG.md"
version_heading_re="^## ${version}\$|^## \\[${version}\\]"

if [[ ! -f "$oka_changelog" ]]; then
  echo "check_package_changelogs: missing packages/oka/CHANGELOG.md" >&2
  exit 1
fi
if ! grep -qE "$version_heading_re" "$oka_changelog"; then
  echo "check_package_changelogs: VERSION $version missing from packages/oka/CHANGELOG.md" >&2
  exit 1
fi

missing=()

while IFS= read -r package; do
  changelog="$ROOT_DIR/packages/$package/CHANGELOG.md"
  if [[ ! -f "$changelog" ]]; then
    missing+=("$package (no CHANGELOG.md)")
    continue
  fi
  if [[ "$package" == "oka" ]]; then
    continue
  fi
  if grep -qE "$version_heading_re" "$changelog"; then
    continue
  fi
  if grep -qF "$train_marker" "$changelog"; then
    continue
  fi
  missing+=("$package")
done < <(dart "$ROOT_DIR/tool/release/train.dart" list)

if ((${#missing[@]} > 0)); then
  echo "check_package_changelogs: VERSION $version missing from (no heading and no train marker):" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "check_package_changelogs: oka mentions $version; train packages satisfied"
