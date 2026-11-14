#!/usr/bin/env bash
# Freeze follower CHANGELOG headings after a release-please merge so RP generic
# extra-files only rewrites lines carrying x-release-please-version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bash tool/release/freeze_follower_changelogs.sh [--check]
  bash tool/release/freeze_follower_changelogs.sh --apply --released X --next Y [--dry-run]

  --check   Run follower changelog validation (default).
  --apply   Move released section content under a frozen ## X heading and add
            upcoming ## Y <!-- x-release-please-version --> above it.
EOF
}

mode="check"
apply_args=()

while (($# > 0)); do
  case "$1" in
    --check)
      mode="check"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      while (($# > 0)) && [[ "$1" != --check ]]; do
        apply_args+=("$1")
        shift
      done
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "freeze_follower_changelogs: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$mode" in
  check)
    exec bash "$SCRIPT_DIR/check_package_changelogs.sh"
    ;;
  apply)
    exec dart "$SCRIPT_DIR/freeze_follower_changelogs.dart" --apply "${apply_args[@]}"
    ;;
esac