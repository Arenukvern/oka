#!/usr/bin/env bash
# actionlint v1.7.7 — checksum-pinned (linux_amd64 tarball from upstream release).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTIONLINT_VERSION="1.7.7"
ACTIONLINT_SHA256="023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757"
ARCHIVE="/tmp/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
BIN="/tmp/actionlint-${ACTIONLINT_VERSION}"

if [[ ! -x "$BIN" ]]; then
  curl -sSfL \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    -o "$ARCHIVE"
  echo "${ACTIONLINT_SHA256}  ${ARCHIVE}" | sha256sum -c -
  tar -xzf "$ARCHIVE" -C /tmp actionlint
  mv /tmp/actionlint "$BIN"
  chmod +x "$BIN"
fi

"$BIN" -color -shellcheck= \
  "$ROOT_DIR"/.github/workflows/*.yml
echo "run_actionlint: OK"