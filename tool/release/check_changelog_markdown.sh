#!/usr/bin/env bash
# Keep a Changelog markdown hygiene: version headings like `## [0.1.6]` are
# intentional (release-please), so MD052 stays disabled at the top; bullets
# must use backticks for code identifiers, not bare [brackets].
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHANGELOG="$ROOT_DIR/packages/oka/CHANGELOG.md"

fail() {
  echo "check_changelog_markdown: $*" >&2
  exit 1
}

ok() {
  echo "check_changelog_markdown: $*"
}

[[ -f "$CHANGELOG" ]] || fail "missing $CHANGELOG"

head -5 "$CHANGELOG" | grep -q "markdownlint-disable MD052" ||
  fail "CHANGELOG.md must keep the top-level '<!-- markdownlint-disable MD052 -->' (Keep a Changelog bracket headings)"

# Bare [identifier] reference-style links in bullet text (not headings, not real links).
bad="$(
  grep -nE '^\s*-\s+.*\[[A-Za-z][A-Za-z0-9_.]+\]' "$CHANGELOG" \
    | grep -v '\](' || true
)"
if [[ -n "$bad" ]]; then
  echo "FAIL: bare [bracketed] identifiers in CHANGELOG bullets — use backticks instead:" >&2
  echo "$bad" >&2
  exit 1
fi

ok "changelog markdown is clean"
