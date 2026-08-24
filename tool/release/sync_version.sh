#!/usr/bin/env bash
# Synchronize the oka one-version train from VERSION.
#
# Usage:
#   tool/release/sync_version.sh [--version <semver>]
#
# If --version is supplied, VERSION is updated first. All other release
# touchpoints are derived from VERSION: pubspec.yaml and the plugin
# manifests (Cursor / Codex / Claude) + marketplace catalog.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

usage() {
  cat <<USAGE
Usage: tool/release/sync_version.sh [--version <semver>]

Synchronizes pubspec.yaml, plugin manifests, and the marketplace catalog
from root VERSION.
USAGE
}

fail() {
  echo "sync_version: $*" >&2
  exit 1
}

version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      version="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$VERSION_FILE" ]] || fail "missing $VERSION_FILE"

if [[ -n "$version" ]]; then
  printf '%s\n' "$version" > "$VERSION_FILE"
fi

repo_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$repo_version" ]] || fail "VERSION file is empty"

# pubspec.yaml
sed -i.bak -E "s/^version:.*/version: ${repo_version}/" "$ROOT_DIR/pubspec.yaml"
rm -f "$ROOT_DIR/pubspec.yaml.bak"

# plugin manifests (jsonpath $.version — top-level only)
for manifest in \
  "$ROOT_DIR/plugin/.cursor-plugin/plugin.json" \
  "$ROOT_DIR/plugin/.codex-plugin/plugin.json" \
  "$ROOT_DIR/plugin/.claude-plugin/plugin.json"; do
  if [[ -f "$manifest" ]]; then
    dart -e '
import "dart:convert";
import "dart:io";
void main(List<String> args) {
  final file = File(args[0]);
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  json["version"] = args[1];
  const encoder = JsonEncoder.withIndent("  ");
  file.writeAsStringSync(encoder.convert(json) + "\n");
}
' "$manifest" "$repo_version"
  fi
done

# marketplace catalog ($.plugins[0].version)
marketplace="$ROOT_DIR/.claude-plugin/marketplace.json"
if [[ -f "$marketplace" ]]; then
  dart -e '
import "dart:convert";
import "dart:io";
void main(List<String> args) {
  final file = File(args[0]);
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  (json["plugins"] as List<dynamic>).first["version"] = args[1];
  const encoder = JsonEncoder.withIndent("  ");
  file.writeAsStringSync(encoder.convert(json) + "\n");
}
' "$marketplace" "$repo_version"
fi

echo "sync_version: all touchpoints set to $repo_version"
