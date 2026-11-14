#!/usr/bin/env bash
# After release-please creates a release on main: freeze follower changelogs and
# open (or reuse) a follow-up PR. Bash 3.2 compatible.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
released="${1:-}"
if [[ -z "$released" ]]; then
  echo "freeze_follower_release_pr: usage: RELEASED_VERSION" >&2
  exit 2
fi

next="$(dart "$ROOT_DIR/tool/release/semver_tool.dart" bump-minor "$released")"
token="${RELEASE_PLEASE_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$token" ]]; then
  echo "freeze_follower_release_pr: RELEASE_PLEASE_TOKEN or GITHUB_TOKEN required" >&2
  exit 1
fi

export GH_TOKEN="$token"
branch="chore/freeze-follower-changelogs-v${released}"

dart "$ROOT_DIR/tool/release/freeze_follower_changelogs.dart" \
  --apply --released "$released" --next "$next"

if git -C "$ROOT_DIR" diff --quiet && git -C "$ROOT_DIR" diff --cached --quiet; then
  echo "freeze_follower_release_pr: no changelog changes; skipping PR"
  exit 0
fi

git -C "$ROOT_DIR" config user.name "github-actions[bot]"
git -C "$ROOT_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$ROOT_DIR" checkout "$branch"
else
  git -C "$ROOT_DIR" checkout -b "$branch"
fi

git -C "$ROOT_DIR" add packages/*/CHANGELOG.md
git -C "$ROOT_DIR" commit -m "chore: freeze follower changelogs after v${released}"

if git -C "$ROOT_DIR" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git -C "$ROOT_DIR" push origin "HEAD:$branch"
else
  git -C "$ROOT_DIR" push -u origin "$branch"
fi

existing_pr="$(gh pr list --repo "${GITHUB_REPOSITORY}" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
  echo "freeze_follower_release_pr: reused open PR #${existing_pr} on ${branch}"
  exit 0
fi

gh pr create --repo "${GITHUB_REPOSITORY}" \
  --base main \
  --head "$branch" \
  --title "chore: freeze follower changelogs after v${released}" \
  --body "Automated follower CHANGELOG freeze after release **v${released}** (upcoming marked heading **${next}**).

Run \`bash tool/contracts/check_contracts.sh\` before merge."
echo "freeze_follower_release_pr: opened PR for ${branch}"