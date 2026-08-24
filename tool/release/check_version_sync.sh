#!/usr/bin/env bash
# Verifies repo VERSION matches every oka release touchpoint:
# pubspec.yaml and the plugin/marketplace manifests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

fail() {
  echo "check_version_sync: $*" >&2
  exit 1
}

ok() {
  echo "check_version_sync: $*"
}

[[ -f "$VERSION_FILE" ]] || fail "missing $VERSION_FILE"
repo_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$repo_version" ]] || fail "VERSION file is empty"

pubspec_version="$(
  sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$ROOT_DIR/pubspec.yaml" | head -1
)"
[[ "$pubspec_version" == "$repo_version" ]] ||
  fail "pubspec.yaml version ($pubspec_version) != VERSION ($repo_version)"

for manifest in \
  "$ROOT_DIR/plugin/.cursor-plugin/plugin.json" \
  "$ROOT_DIR/plugin/.codex-plugin/plugin.json" \
  "$ROOT_DIR/plugin/.claude-plugin/plugin.json"; do
  [[ -f "$manifest" ]] || continue
  manifest_version="$(
    sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -1
  )"
  [[ "$manifest_version" == "$repo_version" ]] ||
    fail "${manifest#$ROOT_DIR/} version ($manifest_version) != VERSION ($repo_version)"
done

marketplace="$ROOT_DIR/.claude-plugin/marketplace.json"
if [[ -f "$marketplace" ]]; then
  marketplace_version="$(
    sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$marketplace" | head -1
  )"
  [[ "$marketplace_version" == "$repo_version" ]] ||
    fail ".claude-plugin/marketplace.json version ($marketplace_version) != VERSION ($repo_version)"
fi

ok "all release touchpoints match VERSION ($repo_version)"
