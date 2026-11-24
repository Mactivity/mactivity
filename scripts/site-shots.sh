#!/bin/bash
# Screenshots for mactivity.app (website/shots/), taken from the real app so Liquid Glass renders
# as it does on screen. Simulated data, a throwaway home: nothing from this Mac shows up.
#
#   make site-shots            every shot, light and dark
#   make site-shots ONLY=cpu   one shot
#
# Needs Screen Recording for the terminal you run it from (System Settings → Privacy & Security →
# Screen & System Audio Recording). macOS asks the first time; allow it, reopen the terminal, rerun.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$MACTIVITY_ROOT"
cd "$ROOT"
OUT="$ROOT/website/shots"
WORK="$ROOT/build/SiteShots.noindex"
DERIVED="$WORK/DerivedData"
APP="$DERIVED/Build/Products/Release/Mactivity.app"
# Tabs for the tour and feature rows. "menubar" is the menu bar window: the script asks you to
# click the Mactivity icon (the menu bar may hide it behind the notch, so it can't click it itself).
SHOTS=(overview cpu memory network history projects storage startup battery volume alerts menubar)
[[ -n "${ONLY:-}" ]] && SHOTS=("$ONLY")
WIDTH=1650 # 1.5× the 1100 pt window: sharp on Retina, a third lighter than 2×

mkdir -p "$OUT" "$WORK"
# Fail fast, before the build, if this terminal can't record the screen.
if ! screencapture -x "$WORK/check.png" 2>/dev/null || [[ ! -s "$WORK/check.png" ]]; then
    echo "This terminal needs Screen Recording: System Settings → Privacy & Security →" >&2
    echo "Screen & System Audio Recording → turn on your terminal app, quit and reopen it, run again." >&2
    exit 1
fi
rm -f "$WORK/check.png"
# Launching while a copy is still quitting (it saves history on the way out) fails with
# Launch Services error -600, so wait until it's gone.
wait_gone() { # wait_gone <pgrep -f pattern>
    for _ in $(seq 40); do
        pgrep -f "$1" >/dev/null || return 0
        sleep 0.25
    done
}

RUNNING=""
# Cleans up and reopens your own copy however the run ends, including on a failed capture.
cleanup() {
    pkill -f "$APP/Contents/MacOS/Mactivity" 2>/dev/null || true
    wait_gone "$APP/Contents/MacOS/Mactivity"
    rm -rf "$DERIVED" "$WORK"/home.*
    if [[ -n "$RUNNING" ]]; then open "$RUNNING"; fi
}
trap cleanup EXIT
# A Release build: Debug adds developer toggles to the toolbar and menu bar window. It's ~1.3 GB,
# so it's removed when the run ends.
echo "Building a Release copy…"
build_release "$DERIVED"

# Finds the window to capture: the app's largest window, or its menu bar window.
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
    // The menu bar shot launches with no main window, so its largest window is the menu bar
    // window; skip the menu-bar-high strips that host the status item. Otherwise, the main window.
    guard menuBar ? (bounds["Height"] ?? 0) > 100 : layer == 0 else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > best.area, let id = window[kCGWindowNumber as String] as? Int { best = (id, area) }
}
print(best.id)
SWIFT
swiftc -O "$WORK/winid.swift" -o "$WORK/winid" 2>/dev/null

shoot() { # shoot <tab> <light|dark>
    local tab=$1 look=$2 home pid="" wid args=()
    home="$(mktemp -d "$WORK/home.XXXXXX")"
    if [[ "$tab" == "menubar" ]]; then
        args=(--background)
    else
        args=(-MeasureInitialTab "$tab")
    fi
    open -n --env CFFIXED_USER_HOME="$home" "$APP" --args -simulatedData YES -hasCompletedOnboarding YES \
        -MeasureScreenshotMode YES -appearance "$look" -menuBarMode icon "${args[@]}"
    for _ in $(seq 20); do
        pid="$(pgrep -n -f "$APP/Contents/MacOS/Mactivity" || true)"
        [[ -n "$pid" ]] && break
        sleep 0.5
    done
    [[ -n "$pid" ]] || { echo "Mactivity didn't start (shot: $tab, $look)." >&2; exit 1; }
    sleep "${WAIT:-10}" # simulated history fills in and charts settle
    if [[ "$tab" == "menubar" ]]; then
        read -r -p "  Click Mactivity's icon in the menu bar ($look mode), then press Return here… " _ </dev/tty
        sleep 1
    fi
    wid="$("$WORK/winid" "$pid" "$tab")"
    if [[ "$wid" == 0 ]] || ! screencapture -x -o -l"$wid" "$WORK/$tab-$look.png" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        echo "Couldn't capture the window. Give this terminal Screen Recording in System Settings →" >&2
        echo "Privacy & Security → Screen & System Audio Recording, reopen it, and run again." >&2
        exit 1
    fi
    kill "$pid" 2>/dev/null || true
    wait_gone "$APP/Contents/MacOS/Mactivity"
    sips -Z "$WIDTH" "$WORK/$tab-$look.png" --out "$OUT/$tab-$look.png" >/dev/null
    rm -f "$WORK/$tab-$look.png"
    echo "  ✓ shots/$tab-$look.png"
}

# Your own copy would share the menu bar; quit it for the run (the trap reopens it).
if pgrep -xq Mactivity; then
    RUNNING="$(ps -axo comm= | grep -m1 '/Mactivity.app/Contents/MacOS/Mactivity$' | sed 's|/Contents/MacOS/Mactivity$||' || true)"
    osascript -e 'tell application "Mactivity" to quit' >/dev/null 2>&1 || true
    wait_gone '/Mactivity.app/Contents/MacOS/Mactivity$'
fi
for tab in "${SHOTS[@]}"; do
    for look in light dark; do
        shoot "$tab" "$look"
    done
done
echo "Done. Preview with make site-preview, publish with make site."
