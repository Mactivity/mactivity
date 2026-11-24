#!/bin/bash
# Tester build (D-073): Release, ad-hoc signed rather than Developer ID signed and notarized
# (that's make release), zipped into dist/.
# Testers open it once through System Settings → Privacy & Security → Open Anyway.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DERIVED=build/Beta.noindex
trap 'rm -rf "$DERIVED"' EXIT

build_release "$DERIVED"

APP="$DERIVED/Build/Products/Release/Mactivity.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
CHANNEL=$(/usr/libexec/PlistBuddy -c "Print :MactivityReleaseChannel" "$APP/Contents/Info.plist" 2>/dev/null || true)
NAME="Mactivity-$VERSION${CHANNEL:+-$CHANNEL}"

# Ad-hoc signature over the whole bundle, nested code first (helper, CLI, widget, Sparkle).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
scripts/size.sh 50 "$APP"

mkdir -p dist
rm -f "dist/$NAME.zip"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
echo "dist/$NAME.zip: $(( $(stat -f %z "dist/$NAME.zip") / 1024 / 1024 )) MB, sha256 $(shasum -a 256 "dist/$NAME.zip" | cut -d' ' -f1)"

# The drag-to-install DMG (D-075). Needs a logged-in session, since Finder lays out the window.
scripts/dmg.sh "$APP" "dist/$NAME.dmg"
echo "dist/$NAME.dmg: sha256 $(shasum -a 256 "dist/$NAME.dmg" | cut -d' ' -f1)"
