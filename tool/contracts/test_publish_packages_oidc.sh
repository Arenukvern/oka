#!/usr/bin/env bash
# Contract: pub.dev train publish OIDC wiring (PR #24 follow-ups).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
publish_script="$ROOT_DIR/tool/release/publish_packages.sh"
workflow="$ROOT_DIR/.github/workflows/pub_publish.yml"

fail() {
  echo "test_publish_packages_oidc: $*" >&2
  exit 1
}

[[ -f "$publish_script" ]] || fail "missing $publish_script"
[[ -f "$workflow" ]] || fail "missing $workflow"

unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
set +e
output="$(bash "$publish_script" --publish 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "--publish must exit non-zero without OIDC env (got $status)"
[[ "$output" == *"--publish requires GitHub Actions OIDC env"* ]] || \
  fail "--publish must print clear OIDC message; got: $output"

publish_region="$(awk '/^for package in/,/^done$/' "$publish_script")"
[[ "$publish_region" == *"refresh_pub_oidc_token"* ]] || \
  fail "refresh_pub_oidc_token must be inside the per-package for loop"
refresh_pos="$(grep -n 'refresh_pub_oidc_token' <<<"$publish_region" | head -1 | cut -d: -f1)"
publish_pos="$(grep -n 'dart pub publish --force' <<<"$publish_region" | head -1 | cut -d: -f1)"
[[ -n "$refresh_pos" && -n "$publish_pos" && "$refresh_pos" -lt "$publish_pos" ]] || \
  fail "refresh_pub_oidc_token must appear before dart pub publish --force in the loop"

if grep -q 'env\.ACTIONS_ID_TOKEN_REQUEST' "$workflow"; then
  fail "pub_publish.yml must not reference env.ACTIONS_ID_TOKEN_REQUEST (runner injects OIDC vars)"
fi

echo "test_publish_packages_oidc: publish OIDC contracts ok"
