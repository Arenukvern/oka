#!/usr/bin/env bash
# actionlint v1.7.7 — checksum-pinned per platform tarball from upstream release.
# SHA256 values from actionlint_1.7.7_checksums.txt at
# https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_checksums.txt
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTIONLINT_VERSION="1.7.7"
ACTIONLINT_CACHE_DIR="${TMPDIR:-/tmp}/oka-actionlint"

declare -A ACTIONLINT_SHA256=(
  [linux_amd64]=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
  [linux_arm64]=401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0
  [darwin_amd64]=28e5de5a05fc558474f638323d736d822fff183d2d492f0aecb2b73cc44584f5
  [darwin_arm64]=2693315b9093aeacb4ebd91a993fea54fc215057bf0da2659056b4bc033873db
)

verify_sha256() {
  local archive="$1" expected="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${expected}  ${archive}" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    echo "${expected}  ${archive}" | shasum -a 256 -c -
  else
    echo "run_actionlint: need sha256sum or shasum to verify ${archive}" >&2
    return 1
  fi
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64 | amd64) echo linux_amd64 ;;
        aarch64 | arm64) echo linux_arm64 ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        x86_64 | amd64) echo darwin_amd64 ;;
        arm64) echo darwin_arm64 ;;
      esac
      ;;
  esac
}

platform="${OKA_ACTIONLINT_PLATFORM:-}"
if [[ -z "$platform" ]]; then
  platform="$(detect_platform)"
fi

if [[ -z "$platform" || -z "${ACTIONLINT_SHA256[$platform]+_}" ]]; then
  echo "run_actionlint: unsupported platform (${platform:-$(uname -s)/$(uname -m)}); skipping (CI ubuntu-latest linux/amd64 validates workflows)" >&2
  exit 0
fi

platform_dir="$ACTIONLINT_CACHE_DIR/${ACTIONLINT_VERSION}/${platform}"
mkdir -p "$platform_dir"
archive="$platform_dir/actionlint_${ACTIONLINT_VERSION}_${platform}.tar.gz"
bin="$platform_dir/actionlint"

if [[ ! -x "$bin" ]]; then
  curl -sSfL \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${platform}.tar.gz" \
    -o "$archive"
  verify_sha256 "$archive" "${ACTIONLINT_SHA256[$platform]}"
  tar -xzf "$archive" -C "$platform_dir" actionlint
  chmod +x "$bin"
fi

"$bin" -color -shellcheck= \
  "$ROOT_DIR"/.github/workflows/*.yml
echo "run_actionlint: OK"