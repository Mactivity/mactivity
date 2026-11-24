#!/bin/bash
# The app's package pins (Sparkle and GRDB) live in App/Package.resolved; the package's own
# (GRDB only) in Packages/MactivityKit/Package.resolved. Without an app-level file, Xcode wrote the
# app's whole graph into the package's file and `swift test` wrote it back, so it flipped between
# the two on every build (D-183).
#
#   scripts/pin-packages.sh          Puts App/Package.resolved where Xcode reads it. XcodeGen runs
#                                    this after every generate (project.yml postGenCommand).
#   scripts/pin-packages.sh --save   After moving a pin on purpose (xcodebuild
#                                    -resolvePackageDependencies, or Xcode's Update to Latest),
#                                    copies Xcode's file back to App/Package.resolved.
#   scripts/pin-packages.sh --check  Fails when the two files pin GRDB at different revisions
#                                    (make lint): the app and the package tests must build the same.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=App/Package.resolved
PACKAGE=Packages/MactivityKit/Package.resolved
XCODE=Mactivity.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

revision() {
    /usr/bin/python3 -c 'import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next((p["state"]["revision"] for p in pins if p["identity"] == sys.argv[2]), ""))' "$1" "$2"
}

case "${1:-}" in
    --save)
        cp "$XCODE" "$APP"
        echo "Saved Xcode's pins to $APP."
        ;;
    --check)
        app=$(revision "$APP" grdb.swift)
        package=$(revision "$PACKAGE" grdb.swift)
        if [[ -z "$app" || "$app" != "$package" ]]; then
            echo "GRDB is pinned at ${app:-nothing} for the app ($APP) but ${package:-nothing} for the package ($PACKAGE)." >&2
            echo "Resolve both to the same version: swift package resolve in the package, then the app (scripts/pin-packages.sh --save)." >&2
            exit 1
        fi
        ;;
    "")
        mkdir -p "$(dirname "$XCODE")"
        cp "$APP" "$XCODE"
        ;;
    *)
        echo "usage: scripts/pin-packages.sh [--save | --check]" >&2
        exit 2
        ;;
esac
