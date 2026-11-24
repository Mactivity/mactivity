#!/bin/bash
# Makes a drag-to-install DMG like Chrome's: a window showing Mactivity, an arrow, and an
# Applications shortcut over a background (D-075). Apple tools only: hdiutil, Finder scripting.
#   scripts/dmg.sh <path/to/Mactivity.app> <output.dmg>
# Finder lays the window out, so this needs a logged-in session. The first run asks to let the
# terminal control Finder. Signing and notarizing the DMG is scripts/release.sh's job.
set -euo pipefail

APP="$1"
OUT="$2"
VOLUME="Mactivity"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

# A volume of the same name left mounted would make Finder lay out the wrong window.
hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/dmg/background.swift" "$WORK"
# One TIFF with 1x and 2x images, so the background is sharp on Retina displays.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg" -quiet
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -quiet

osascript <<APPLESCRIPT
-- Long enough for the one-time "allow control of Finder" prompt to be answered.
with timeout of 300 seconds
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Mactivity.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
end timeout
APPLESCRIPT

# The hidden background folder stays hidden in Finder; make sure Finder's layout is on disk.
sync
hdiutil detach "/Volumes/$VOLUME" -quiet
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format ULFO -o "$OUT" -quiet
echo "$OUT: $(( $(stat -f %z "$OUT") / 1024 / 1024 )) MB"
