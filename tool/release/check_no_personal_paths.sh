#!/usr/bin/env bash
# Fail if committed files contain maintainer-local absolute paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

matches="$(
  pattern="$(printf '/%s/anton' 'Users')"
  git -C "$ROOT" ls-files | while read -r f; do
    grep -ln "$pattern" "$ROOT/$f" 2>/dev/null || true
  done
)"

if [[ -n "$matches" ]]; then
  echo "FAIL: maintainer-local absolute paths are not allowed in committed files." >&2
  echo "$matches" >&2
  exit 1
fi

echo "OK: no maintainer-local absolute paths"
