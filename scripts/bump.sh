#!/bin/bash
# Sets the version for the next release: `make bump V=0.9.1`.
# MARKETING_VERSION becomes V; CURRENT_PROJECT_VERSION (CFBundleVersion, which Sparkle compares
# to decide whether an update is newer) goes up by one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$MACTIVITY_ROOT"
V="${1:?Usage: make bump V=0.9.1}"
[[ "$V" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "Version must look like 1.0, 0.9.1 or 0.9.7.2" >&2; exit 1; }
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
NEXT=$((BUILD + 1))
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:) \"[^\"]*\"/\1 \"$V\"/; s/^([[:space:]]*CURRENT_PROJECT_VERSION:) \"[0-9]+\"/\1 \"$NEXT\"/" "$ROOT/project.yml"
NOTES="$ROOT/docs/releases/$V.md"
[[ -f "$NOTES" ]] || printf -- "- \n" >"$NOTES"
echo "Version $V, build $NEXT. Write what changed in docs/releases/$V.md (one \"- \" line each);"
echo "it becomes the update's release notes. Then: make release"
