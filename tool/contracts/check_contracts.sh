#!/usr/bin/env bash
# Master contract gate — run before merge. Mirrors CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"
bash tool/release/check_version_sync.sh
bash tool/contracts/check_docs_drift.sh
bash tool/release/check_no_personal_paths.sh
bash tool/release/check_changelog_markdown.sh

echo ""
echo "check-contracts: all gates passed"
