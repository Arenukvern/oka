#!/usr/bin/env bash
# Synchronize all release versions and internal dependencies from VERSION.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec dart "$SCRIPT_DIR/train.dart" sync "$@"
