#!/usr/bin/env bash
# A short demo video of Mactivity (D-124), for the website:
#
#   make demo-video            # build/Mactivity-demo.mp4, dark mode
#   LOOK=light make demo-video
#   NO_RECORD=1 make demo-video   # play the tour without recording (checks the tour itself)
#
# A Release copy runs on simulated data in an empty home folder, so nothing personal shows, and
# tours its tabs by itself (`-MeasureDemoTour YES`, about a minute), then quits. demo-recorder
# films only that window, so the rest of the screen stays out of it and the Mac stays usable.
# Needs Screen Recording for this terminal, like scripts/site-shots.sh.
#
# The steps that can fail fast go first: compiling the recorder and a 2-second test recording,
# before the several-minute build. A failed run keeps the build, so running again is quick; a
# finished one deletes it (~1.3 GB).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$MACTIVITY_ROOT"
cd "$ROOT"
WORK="$ROOT/build/DemoVideo.noindex"
DERIVED="$WORK/DerivedData"
APP="$DERIVED/Build/Products/Release/Mactivity.app"
RECORDER="$WORK/demo-recorder"
OUT="$ROOT/build/Mactivity-demo.mp4"
LOOK="${LOOK:-dark}"
mkdir -p "$WORK"

echo "Compiling the recorder…"
if ! swiftc -O "$ROOT/scripts/demo-recorder.swift" -o "$RECORDER" 2>"$WORK/recorder.log"; then
    grep -A3 "error:" "$WORK/recorder.log" >&2
    exit 1
fi
if [[ -z "${NO_RECORD:-}" ]]; then
    "$RECORDER" check
fi

wait_gone() {
    for _ in $(seq 40); do
        pgrep -f "$1" >/dev/null || return 0
        sleep 0.25
    done
}
HOME_DIR=""
cleanup() {
    local status=$?
    pkill -f "$APP/Contents/MacOS/Mactivity" 2>/dev/null || true
    wait_gone "$APP/Contents/MacOS/Mactivity"
    rm -rf "${HOME_DIR:-/nonexistent}"
    if [[ $status == 0 ]]; then
        rm -rf "$WORK"
    else
        echo "Kept the build in $WORK, so running again is quick. Remove it with: rm -rf \"$WORK\"" >&2
    fi
}
trap cleanup EXIT

echo "Building a Release copy (a few minutes the first time)…"
build_release "$DERIVED"

# Your own Mactivity can keep running: this copy has its own home folder, and only its
# window is filmed. For a moment there are two icons in the menu bar.

HOME_DIR="$(mktemp -d "$WORK/home.XXXXXX")"
# Not with -g: launched hidden, SwiftUI opens no main window. The window comes forward for
# the minute; working in front of it is fine, since only its own pixels are filmed.
open -n --env CFFIXED_USER_HOME="$HOME_DIR" "$APP" --args -simulatedData YES -hasCompletedOnboarding YES \
    -MeasureScreenshotMode YES -MeasureDemoTour YES -appearance "$LOOK" -menuBarMode icon -MeasureInitialTab overview
PID=""
for _ in $(seq 20); do
    PID="$(pgrep -n -f "$APP/Contents/MacOS/Mactivity" || true)"
    [[ -n "$PID" ]] && break
    sleep 0.5
done
[[ -n "$PID" ]] || { echo "Mactivity didn't start." >&2; exit 1; }

if [[ -n "${NO_RECORD:-}" ]]; then
    echo "Playing the tour (not recording)…"
    for _ in $(seq 120); do
        kill -0 "$PID" 2>/dev/null || { echo "The tour finished and Mactivity quit."; exit 0; }
        sleep 1
    done
    echo "The tour didn't finish within two minutes." >&2
    exit 1
fi

echo "Recording the tour (about a minute)…"
"$RECORDER" record "$PID" "$OUT" 90
echo "Done: $OUT"
echo "Upload it as an unlisted YouTube video (or share it from Google Drive) and paste the link."
