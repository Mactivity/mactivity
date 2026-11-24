#!/bin/bash
# The media library: screenshots of every page, short captioned
# clips, the full demo tour, social cards and brand images, plus a README with captions and rules
# for whoever posts from it. A Release copy runs on simulated data in a
# throwaway home folder, so nothing from this Mac shows up.
#
#   make media                          everything, into MarketingCollateral/ (about 20 minutes)
#   OUT=~/Desktop/media make media      somewhere else
#   ONLY="shots cards" make media       some parts: shots, clips, tour, cards (cards reuse the shots and clips)
#   MENUBAR=1 make media                also the menu bar window; asks you to click the icon
#
# MarketingCollateral/ is gitignored: it stays on this Mac.
# Needs Screen Recording for the terminal you run it from, like scripts/site-shots.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$MACTIVITY_ROOT"
cd "$ROOT"
OUT="${OUT:-$ROOT/MarketingCollateral}"
WORK="$ROOT/build/Media.noindex"
DERIVED="$WORK/DerivedData"
APP="$DERIVED/Build/Products/Release/Mactivity.app"
RECORDER="$WORK/demo-recorder"
# Film the window's area of the display, not the window, so macOS doesn't badge it as shared.
export RECORD_DISPLAY_AREA=1
ONLY="${ONLY:-}"
WIDTH=1650 # 1.5× the 1100 pt window, as on the website
# Every page worth showing (Volume is experimental and off by default, so it's left out).
PAGES=(overview checkup cpu gpu memory disk network battery projects agents storage startup devices alerts history)
# Clip name (DemoTour.steps) and the page it starts on.
CLIPS=(glance:overview why-slow:overview apps:cpu metrics:memory battery:battery history:history
    checkup:checkup storage:storage projects:projects alerts:alerts)

part() { [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
mkdir -p "$OUT"/{screenshots,clips,cards,brand} "$WORK"

echo "Compiling the recorder…"
if ! swiftc -O "$ROOT/scripts/demo-recorder.swift" -o "$RECORDER" 2>"$WORK/recorder.log"; then
    grep -A3 "error:" "$WORK/recorder.log" >&2
    exit 1
fi
if part shots || part clips || part tour; then
    "$RECORDER" check
fi

# Finds the window to capture: the app's largest window, or its menu bar window (as in site-shots.sh).
cat >"$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
guard CommandLine.arguments.count > 2, let pid = Int32(CommandLine.arguments[1]) else { exit(1) }
let menuBar = CommandLine.arguments[2] == "menubar"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best = (id: 0, area: 0.0)
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    guard menuBar ? (bounds["Height"] ?? 0) > 100 : layer == 0 else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > best.area, let id = window[kCGWindowNumber as String] as? Int { best = (id, area) }
}
print(best.id)
SWIFT
swiftc -O "$WORK/winid.swift" -o "$WORK/winid" 2>/dev/null

wait_gone() { # wait_gone <pgrep -f pattern>
    for _ in $(seq 40); do
        pgrep -f "$1" >/dev/null || return 0
        sleep 0.25
    done
}
RUNNING=""
cleanup() {
    local status=$?
    pkill -f "$APP/Contents/MacOS/Mactivity" 2>/dev/null || true
    wait_gone "$APP/Contents/MacOS/Mactivity"
    rm -rf "$WORK"/home.*
    if [[ -n "$RUNNING" ]]; then open "$RUNNING"; fi
    # The build is ~1.3 GB: gone after a finished run, kept after a failed one so a rerun is quick.
    if [[ $status == 0 ]]; then
        rm -rf "$WORK"
    else
        echo "Kept the build in $WORK, so running again is quick. Remove it with: rm -rf \"$WORK\"" >&2
    fi
}
trap cleanup EXIT

CAPTURING=""
if part shots || part clips || part tour; then CAPTURING=1; fi
if [[ -n "$CAPTURING" ]]; then
    # Every run, so a build kept from a failed run is never older than the code; quick when it's current.
    echo "Building a Release copy (a few minutes the first time)…"
    build_release "$DERIVED"
fi

PID=""
launch() { # launch <extra arguments…>: a fresh copy on simulated data; sets PID
    local home
    home="$(mktemp -d "$WORK/home.XXXXXX")"
    open -n --env CFFIXED_USER_HOME="$home" "$APP" --args -simulatedData YES -hasCompletedOnboarding YES \
        -MeasureScreenshotMode YES -menuBarMode icon "$@"
    PID=""
    for _ in $(seq 20); do
        PID="$(pgrep -n -f "$APP/Contents/MacOS/Mactivity" || true)"
        [[ -n "$PID" ]] && return 0
        sleep 0.5
    done
    echo "Mactivity didn't start ($*)." >&2
    exit 1
}
stop() {
    kill "$PID" 2>/dev/null || true
    wait_gone "$APP/Contents/MacOS/Mactivity"
}
# film <output.mp4> <max s> <min frames> <launch arguments…>: films a demo tour or clip from
# its first caption to its end. The tour waits until the recorder is filming (the ready file),
# and a take that's cut short or cropped is filmed again, so nothing half-done lands in the library.
film() {
    local out="$1" limit="$2" minimum="$3" attempt
    shift 3
    for attempt in 1 2 3; do
        rm -f "$WORK/ready"
        launch "$@" -MeasureDemoReadyFile "$WORK/ready"
        if RECORD_READY_FILE="$WORK/ready" "$RECORDER" record "$PID" "$out" "$limit" "$minimum" >"$WORK/record.log" 2>&1; then
            wait_gone "$APP/Contents/MacOS/Mactivity"
            echo "  ✓ ${out#"$OUT"/} ($(sed -nE 's/^Recorded ([0-9]+ s).*/\1/p' "$WORK/record.log"))"
            return 0
        fi
        stop
        echo "  ✗ ${out#"$OUT"/}, take $attempt: $(tail -1 "$WORK/record.log")" >&2
    done
    rm -f "$out"
    echo "Couldn't film ${out#"$OUT"/} in three takes." >&2
    exit 1
}
capture() { # capture <tab|menubar> <output.png>
    local wid
    wid="$("$WORK/winid" "$PID" "$1")"
    if [[ "$wid" == 0 ]] || ! screencapture -x -o -l"$wid" "$WORK/capture.png" 2>/dev/null; then
        stop
        echo "Couldn't capture the window ($1)." >&2
        exit 1
    fi
    sips -Z "$WIDTH" "$WORK/capture.png" --out "$2" >/dev/null
    rm -f "$WORK/capture.png"
}

# Your own copy would share the menu bar; quit it for the run (the trap reopens it).
if [[ -n "$CAPTURING" ]] && pgrep -xq Mactivity; then
    RUNNING="$(ps -axo comm= | grep -m1 '/Mactivity.app/Contents/MacOS/Mactivity$' | sed 's|/Contents/MacOS/Mactivity$||' || true)"
    osascript -e 'tell application "Mactivity" to quit' >/dev/null 2>&1 || true
    wait_gone '/Mactivity.app/Contents/MacOS/Mactivity$'
fi

if part shots; then
    echo "Screenshots…"
    for page in "${PAGES[@]}"; do
        for look in dark light; do
            launch -appearance "$look" -MeasureInitialTab "$page"
            sleep "${WAIT:-10}" # simulated history fills in and charts settle
            capture "$page" "$OUT/screenshots/$page-$look.png"
            stop
            echo "  ✓ screenshots/$page-$look.png"
        done
    done
    if [[ -n "${MENUBAR:-}" ]]; then
        for look in dark light; do
            launch -appearance "$look" --background
            sleep "${WAIT:-10}"
            read -r -p "  Click Mactivity's icon in the menu bar ($look mode), then press Return here… " _ </dev/tty
            sleep 1
            capture menubar "$OUT/screenshots/menubar-window-$look.png"
            stop
            echo "  ✓ screenshots/menubar-window-$look.png"
        done
    fi
fi

if part clips; then
    echo "Clips (dark, captioned)…"
    for entry in "${CLIPS[@]}"; do
        name="${entry%%:*}"
        # A calm page sends few frames, so ask for 5.
        film "$OUT/clips/$name.mp4" 60 5 -appearance dark -MeasureDemoTour YES -MeasureDemoClip "$name" \
            -MeasureInitialTab "${entry#*:}"
    done
fi

if part tour; then
    echo "The whole tour, about a minute each…"
    for look in dark light; do
        film "$OUT/clips/tour-$look.mp4" 150 30 -appearance "$look" -MeasureDemoTour YES -MeasureInitialTab overview
    done
fi

if part cards; then
    echo "Cards and brand images…"
    swift "$ROOT/scripts/media-cards.swift" "$ROOT/docs/brand" "$OUT"
fi

# The captions and rules, when the private notes are on this Mac.
[[ -f "$ROOT/docs/private/MEDIA-LIBRARY.md" ]] && cp "$ROOT/docs/private/MEDIA-LIBRARY.md" "$OUT/README.md"
echo "Done: $OUT"
