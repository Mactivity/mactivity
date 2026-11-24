#!/bin/bash
# Install-size budget (D-058): prints what's in the app and fails if the bundle
# passes the budget.
#   scripts/size.sh [budget in MB, default 50] [path to a built Mactivity.app]
# With no app, it archives Release unsigned and removes the archive afterwards so it doesn't sit
# on disk. An archive, because that's what ships: a plain Release build keeps its debug symbols
# and reads about twice the size (74 MB against 40 MB on 2026-11-04).
# make beta and make release pass the app they just built, so there's no second build.
set -euo pipefail

BUDGET_MB="${1:-50}"
APP="${2:-}"
if [ -z "$APP" ]; then
    DERIVED=build/SizeCheck.noindex
    trap 'rm -rf "$DERIVED"' EXIT
    rm -rf "$DERIVED"
    mkdir -p "$DERIVED"
    xcodegen generate --quiet
    if ! xcodebuild -project Mactivity.xcodeproj -scheme Mactivity -configuration Release \
        -derivedDataPath "$DERIVED/DerivedData" -destination 'generic/platform=macOS' \
        -archivePath "$DERIVED/Mactivity.xcarchive" CODE_SIGNING_ALLOWED=NO \
        -quiet archive >"$DERIVED/archive.log" 2>&1; then
        tail -20 "$DERIVED/archive.log" >&2
        echo "The archive failed, so there's nothing to measure." >&2
        exit 1
    fi
    APP="$DERIVED/Mactivity.xcarchive/Products/Applications/Mactivity.app"
fi
if [ ! -d "$APP/Contents/MacOS" ]; then
    echo "No app at $APP." >&2
    exit 1
fi
du -sh "$APP"/Contents/MacOS/* "$APP"/Contents/Frameworks/* "$APP"/Contents/PlugIns/* \
    "$APP"/Contents/Helpers/* "$APP"/Contents/Resources 2>/dev/null | sort -h
KB=$(du -sk "$APP" | cut -f1)
ZIP="$(mktemp -d)/Mactivity.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
ZIP_KB=$(( $(stat -f %z "$ZIP") / 1024 ))
rm -f "$ZIP"

printf "Mactivity.app: %d MB installed, %d MB zipped (budget %d MB installed)\n" \
    $((KB / 1024)) $((ZIP_KB / 1024)) "$BUDGET_MB"
if [ "$KB" -gt $((BUDGET_MB * 1024)) ]; then
    echo "Over the install-size budget." >&2
    exit 1
fi
