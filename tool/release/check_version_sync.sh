#!/usr/bin/env bash
# Validate the complete release inventory and its internal dependencies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec dart "$SCRIPT_DIR/train.dart" check "$@"
