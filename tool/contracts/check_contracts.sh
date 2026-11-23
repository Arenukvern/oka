#!/usr/bin/env bash
# Master contract gate — run before merge. Mirrors CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"
export OKA_ROOT="$ROOT_DIR"
# ADR 0054: the one-version train is retired — per-package versions move
# via dart_changesets; the VERSION file and the release-please manifest
# are gone, so no version-sync / manifest gates here anymore.
bash tool/release/check_package_changelogs.sh
bash tool/release/check_package_licenses.sh
bash tool/contracts/check_docs_drift.sh
dart tool/contracts/check_doc_assets.dart
dart tool/contracts/check_doc_links.dart
dart tool/contracts/check_toolchain_versions.dart
dart tool/contracts/check_example_path_overrides.dart
dart tool/contracts/check_no_directory_current_assignment.dart
dart tool/contracts/check_train_package_lib_workspace_leak.dart
dart tool/contracts/check_duplicate_train_inventory.dart
bash tool/release/check_no_personal_paths.sh
bash tool/release/check_changelog_markdown.sh
bash tool/contracts/run_actionlint.sh
# ADR 0054: publishing is the dart_changesets per-tag CI train — the
# local publish_packages.sh / pub_publish.yml OIDC contract is retired.

echo ""
echo "check-contracts: all gates passed"
