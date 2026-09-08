#!/usr/bin/env bash
# oka installer — curl | bash friendly.
#
#   curl -fsSL https://raw.githubusercontent.com/Arenukvern/oka/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --version 0.1.6
#   curl -fsSL ... | bash -s -- --from-git          # install from main @ HEAD
#
# Installs the `oka` CLI via `dart pub global activate`. Requires Dart
# (https://dart.dev/get-dart); Flutter is NOT required to install.
set -euo pipefail

REPO="${OKA_REPO:-Arenukvern/oka}"
VERSION="${OKA_VERSION:-}"

usage() {
  cat <<USAGE
Usage: ./install.sh [--version <semver>] [--from-git] [--repo <owner/name>]
       curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- [--version <semver>]

Installs the oka CLI via 'dart pub global activate'.
By default: latest published version from pub.dev.
--from-git: activate from this repository's main branch instead.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --from-git) FROM_GIT=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v dart >/dev/null 2>&1 || {
  cat >&2 <<'EOF'
Dart not found. Install it first: https://dart.dev/get-dart
(FLutter includes Dart too — make sure `dart` is on PATH.)
EOF
  exit 1
}

echo "📦 Installing oka via dart pub global activate..."
if [[ "${FROM_GIT:-0}" == "1" ]]; then
  dart pub global activate \
    --source git "https://github.com/${REPO}.git" \
    --path packages/oka
elif [[ -n "$VERSION" ]]; then
  dart pub global activate oka "$VERSION"
else
  dart pub global activate oka
fi

echo
echo "✅ Done! Test with: oka --version"
[[ ":$PATH:" == *":$HOME/.pub-cache/bin:"* ]] || \
  echo "ℹ️  If 'oka' is not found, add \$HOME/.pub-cache/bin to your PATH."
