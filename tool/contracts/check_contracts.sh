#!/usr/bin/env bash
# Master contract gate — run before merge. Mirrors CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"
export OKA_ROOT="$ROOT_DIR"
bash tool/release/check_version_sync.sh
bash tool/release/check_release_please_manifest.sh
bash tool/release/check_package_changelogs.sh
bash tool/release/check_package_licenses.sh
bash tool/contracts/check_docs_drift.sh
dart tool/contracts/check_example_path_overrides.dart
dart tool/contracts/check_no_directory_current_assignment.dart
dart tool/contracts/check_train_package_lib_workspace_leak.dart
bash tool/release/check_no_personal_paths.sh
bash tool/release/check_changelog_markdown.sh
bash tool/contracts/run_actionlint.sh
bash tool/contracts/test_publish_packages_oidc.sh

echo ""
echo "check-contracts: all gates passed"
