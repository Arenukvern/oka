#!/usr/bin/env bash
# Keep release-please's last-released version aligned with VERSION.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
manifest="$ROOT_DIR/.release-please-manifest.json"

if [[ ! -f "$manifest" ]]; then
  echo "check_release_please_manifest: missing $manifest" >&2
  exit 1
fi

manifest_version="$(dart "$ROOT_DIR/tool/release/read_manifest_version.dart" "$ROOT_DIR")"

if [[ "$manifest_version" != "$version" ]]; then
  echo "check_release_please_manifest: VERSION ($version) != .release-please-manifest.json (.$manifest_version)" >&2
  echo "Run: echo '{\".\": \"$version\"}' > .release-please-manifest.json (or bump both via release train)" >&2
  exit 1
fi

echo "check_release_please_manifest: manifest matches VERSION ($version)"
