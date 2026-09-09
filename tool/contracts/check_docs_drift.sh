#!/usr/bin/env bash
# Verifies docs stay in sync with the CLI surface: every documented command
# and config key must exist in code; key doc files must reference the
# non-negotiables.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "check_docs_drift: $*" >&2
  exit 1
}

ok() {
  echo "check_docs_drift: $*"
}

require_file_contains() {
  local file="$1" token="$2" label="$3"
  if ! grep -Fq -- "$token" "$file" 2>/dev/null; then
    fail "docs drift: '$token' missing from $label ($file)"
  fi
}

# Non-negotiables must remain documented in the agent map + charter.
require_file_contains "$ROOT_DIR/AGENTS.md" \
  "flutter build apk" "AGENTS.md (no-Gradle invariant)"
require_file_contains "$ROOT_DIR/docs/start_here/why_this_repo_matters.mdx" \
  "never" "charter (invariants)"

# Build guide must document the current fast-settings surface.
for key in extra_deps extra_assets deeplinks local_aars; do
  require_file_contains "$ROOT_DIR/docs/guides/build_and_config.mdx" \
    "$key" "build guide (oka.yaml pipeline keys)"
done
require_file_contains "$ROOT_DIR/docs/guides/build_and_config.mdx" \
  "icon" "build guide (android.icon)"

# README must point at the published docs site.
require_file_contains "$ROOT_DIR/README.md" \
  "docs.page/arenukvern/oka" "README"

# Every sidebar entry in docs.json must resolve to a file under docs/.
python3 - <<'EOF'
import json, os, sys
root = os.environ.get("OKA_ROOT", os.getcwd())
cfg = json.load(open(os.path.join(root, "docs.json")))
missing = []
def walk(items):
    for it in items:
        href = it.get("href", "")
        if href.startswith("http"):
            continue
        path = href.lstrip("/")
        if path == "":
            path = "index.mdx"
        elif not os.path.splitext(path)[1]:
            # docs.page serves .mdx; sidebar hrefs are extensionless routes
            path = path + ".mdx"
        if not os.path.exists(os.path.join(root, "docs", path)):
            missing.append(href)
for g in cfg["sidebar"]:
    walk(g["pages"])
if missing:
    print("check_docs_drift: docs.json sidebar entries missing files: %s" % missing, file=sys.stderr)
    sys.exit(1)
EOF

ok "docs are in sync"
