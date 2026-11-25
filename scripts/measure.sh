#!/bin/bash
# CPU and memory of a Release build in a throwaway home, so it never touches real history or
# preferences.
#   scripts/measure.sh [seconds]        idle: menu bar only, the budget in CLAUDE.md rule 5
#   CLOSED=1 scripts/measure.sh [seconds]
#                                       idle again after the window has been open for 30 s, the
#                                       second memory budget (D-268). The opened-and-closed state
#                                       is where real use ends up, and an idle launch can't see it.
#   scripts/measure.sh [seconds] cpu    main window open on a sidebar tab (overview, cpu, …).
#                                       Opens in front: macOS doesn't open the window of an app
#                                       launched in the background, so don't type into it meanwhile.
# The menu bar item, always passed as launch arguments: CFFIXED_USER_HOME doesn't redirect
# preferences, so anything left out would come from this Mac's own settings. Defaults: icon mode,
# CPU for figure and graph, CPU and memory for stacked, glyph on, graph with its figure.
#   MENUBAR=stacked STACKED=cpu,memory,gpu,network scripts/measure.sh 300
#   MENUBAR=figure METRIC=network scripts/measure.sh 300
#   GLYPH=NO hides the pulse glyph; GRAPH_VALUE=NO draws graph mode's bars without the figure.
#   VOLUME=YES turns per-app volume on (about 3 MB, D-268).
#   PROFILE=/tmp/mactivity.txt also writes a `sample` call tree for the run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$MACTIVITY_ROOT"

DURATION="${1:-300}"
TAB="${2:-}"
CLOSED="${CLOSED:-}"
if [ -n "$CLOSED" ]; then
    TAB="${TAB:-overview}"
    # Memory settles within a minute or so of the close (D-270).
    WARMUP="${WARMUP:-150}"
fi
WARMUP="${WARMUP:-60}"
DERIVED=build/MeasureDerivedData.noindex
MENUBAR="${MENUBAR:-icon}"
LAUNCH_ARGS=(
    -hasCompletedOnboarding YES
    -menuBarMode "$MENUBAR"
    -menuBarMetric "${METRIC:-cpu}"
    -menuBarStackedMetrics "${STACKED:-cpu,memory}"
    -menuBarShowsGlyph "${GLYPH:-YES}"
    -menuBarGraphShowsValue "${GRAPH_VALUE:-YES}"
    -perAppVolume "${VOLUME:-NO}"
    -SUEnableAutomaticChecks NO
)
build_release "$DERIVED"

APP="$MACTIVITY_ROOT/$DERIVED/Build/Products/Release/Mactivity.app"
COPY_ID=app.mactivity.Measure
HOME_DIR="$(mktemp -d)"
PID=""
cleanup() {
    [ -z "$PID" ] || stop_copy "$PID"
    forget_copy "$APP" "$COPY_ID"
    # The Release build is ~1.3 GB; don't leave it on disk between measurements.
    rm -rf "$HOME_DIR" "$DERIVED"
}
trap cleanup EXIT
isolate_copy "$APP" "$COPY_ID"
# Through Launch Services, not exec'd from this shell: otherwise privacy checks (Bluetooth)
# judge the terminal's Info.plist instead of Mactivity's and abort the process.
if [ -n "$TAB" ]; then
    WINDOW_ARGS=(-MeasureInitialTab "$TAB")
    [ -n "$CLOSED" ] && WINDOW_ARGS+=(-MeasureCloseAfter 30)
    open -n --env CFFIXED_USER_HOME="$HOME_DIR" "$APP" --args "${WINDOW_ARGS[@]}" "${LAUNCH_ARGS[@]}"
else
    open -n -g --env CFFIXED_USER_HOME="$HOME_DIR" "$APP" --args --background "${LAUNCH_ARGS[@]}"
fi
for _ in $(seq 20); do
    PID="$(pgrep -n -f "$APP/Contents/MacOS/Mactivity" || true)"
    [ -n "$PID" ] && break
    sleep 0.5
done
[ -n "$PID" ] || { echo "Mactivity didn't start." >&2; exit 1; }

cpu_seconds() {
    # ps prints [[dd-]hh:]mm:ss.cc
    ps -o time= -p "$PID" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

# The budget is physical footprint (what Mactivity and Activity Monitor call Memory), not RSS,
# which also counts shared system framework pages.
footprint_now() {
    footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }'
}

sleep "$WARMUP"
# A window that never opened would read as a very good result. macOS doesn't open one while the
# screen is locked, and an open window has always peaked well over 100 MB.
if [ -n "$CLOSED" ]; then
    PEAK="$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint_peak:/ { print int($3 == "GB" ? $2 * 1024 : $2); exit }')"
    if [ "${PEAK:-0}" -lt 100 ]; then
        echo "The window never opened (peak ${PEAK:-0} MB), so this isn't the closed case. Is the screen locked?" >&2
        exit 1
    fi
fi
START="$(cpu_seconds)"
# Footprint at both ends of the run, so growth (say, a leak per menu bar redraw) shows.
FOOTPRINT_START="$(footprint_now)"
if [ -n "${PROFILE:-}" ]; then
    # PROFILE=<file>: where the time goes, from `sample` every 10 ms. Sampling costs the app a
    # little, so read the call tree, not this run's percentage.
    sample "$PID" "$DURATION" 10 -mayDie -file "$PROFILE" >/dev/null 2>&1
else
    sleep "$DURATION"
fi
kill -0 "$PID" 2>/dev/null || { echo "Mactivity exited during the measurement." >&2; exit 1; }
END="$(cpu_seconds)"
FOOTPRINT="$(footprint_now)"

MODE="Idle, menu bar $MENUBAR${METRIC:+ $METRIC}${STACKED:+ $STACKED}"
BUDGET=" (budget: 0.5%, 35 MB)"
if [ -n "$CLOSED" ]; then
    MODE="Window opened on $TAB and closed, menu bar $MENUBAR"
    BUDGET=" (budget: 0.5%, 75 MB)"
elif [ -n "$TAB" ]; then
    MODE="Window on $TAB"
    BUDGET=""
fi
awk -v start="$START" -v end="$END" -v duration="$DURATION" -v footprint="$FOOTPRINT" \
    -v first="$FOOTPRINT_START" -v mode="$MODE" -v budget="$BUDGET" 'BEGIN {
    printf "%s over %d s: %.3f%% of one core, %s memory (%s at the start)%s\n",
        mode, duration, (end - start) / duration * 100, footprint, first, budget
}'
