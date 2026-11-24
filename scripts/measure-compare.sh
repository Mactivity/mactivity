#!/usr/bin/env bash
# Idle CPU and memory of two builds, measured at the same time, so both see the same load:
#
#   scripts/measure-compare.sh <revision A> [revision B, default HEAD] [seconds, default 300]
#   make measure-compare A=dfe322d B=HEAD S=300
#
# A single `make measure` on a Mac in use reads whatever else the desktop is doing (menu bar
# redraws, app switches): 0.08% on a quiet evening, 0.23% while working. Two builds side by side
# answer "did this change cost anything" whatever the load. Each is a Release build of
# its revision, in its own worktree, with its own empty home folder; both are deleted afterwards.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

A_REV="${1:?usage: measure-compare.sh <revision A> [revision B] [seconds]}"
B_REV="${2:-HEAD}"
DURATION="${3:-300}"
WARMUP=30
WORK="$(mktemp -d)"
PIDS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [ -z "$pid" ] || stop_copy "$pid"
    done
    for name in a b; do
        forget_copy "$WORK/$name-derived/Build/Products/Release/Mactivity.app" "app.mactivity.Measure.$name"
        git -C "$MACTIVITY_ROOT" worktree remove --force "$WORK/$name" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

build() {
    local name="$1" rev="$2"
    git -C "$MACTIVITY_ROOT" worktree add --detach "$WORK/$name" "$rev" >/dev/null 2>&1
    echo "→ Building $rev"
    (cd "$WORK/$name" && build_release "$WORK/$name-derived")
}

launch() {
    local name="$1" app="$WORK/$1-derived/Build/Products/Release/Mactivity.app"
    mkdir -p "$WORK/$name-home"
    isolate_copy "$app" "app.mactivity.Measure.$name"
    open -n -g --env CFFIXED_USER_HOME="$WORK/$name-home" "$app" --args --background -hasCompletedOnboarding YES \
        -menuBarMode icon -perAppVolume NO -SUEnableAutomaticChecks NO
    local pid=""
    for _ in $(seq 20); do
        pid="$(pgrep -n -f "$app/Contents/MacOS/Mactivity" || true)"
        [ -n "$pid" ] && break
        sleep 0.5
    done
    [ -n "$pid" ] || { echo "The $name build didn't start." >&2; exit 1; }
    echo "$pid"
}

cpu_seconds() {
    ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

footprint_mb() {
    footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }'
}

build a "$A_REV"
build b "$B_REV"
A_PID="$(launch a)"
PIDS+=("$A_PID")
B_PID="$(launch b)"
PIDS+=("$B_PID")
echo "→ Both running; measuring for $DURATION s after a $WARMUP s warm-up"
sleep "$WARMUP"
A_START="$(cpu_seconds "$A_PID")"
B_START="$(cpu_seconds "$B_PID")"
sleep "$DURATION"
for pid in "$A_PID" "$B_PID"; do
    kill -0 "$pid" 2>/dev/null || { echo "A build exited during the measurement." >&2; exit 1; }
done
A_END="$(cpu_seconds "$A_PID")"
B_END="$(cpu_seconds "$B_PID")"
load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
report() {
    awk -v s="$2" -v e="$3" -v d="$DURATION" -v rev="$1" -v mem="$4" \
        'BEGIN { printf "%-12s %.3f%% of one core, %s memory\n", rev, (e - s) / d * 100, mem }'
}
echo "Idle, menu bar icon, both over the same $DURATION s (load average $load):"
report "$A_REV" "$A_START" "$A_END" "$(footprint_mb "$A_PID")"
report "$B_REV" "$B_START" "$B_END" "$(footprint_mb "$B_PID")"
