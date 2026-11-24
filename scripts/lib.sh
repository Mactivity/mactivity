# Shared by the build, measurement, and release scripts. Source it, don't run it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# `/bin/pwd -P`: the folder's real name (bash's own `pwd -P` keeps the case as typed). Run from ~/developer/mactivity, plain `pwd` keeps that
# spelling, but macOS launches apps under the real one (~/Developer/Mactivity), so looking the
# running copy up by its path found nothing ("Mactivity didn't start").
MACTIVITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"

# build_release <derived data folder>: regenerates the project, then builds Release
# for Apple silicon. Run from the repository root (make does). The app lands at
# <folder>/Build/Products/Release/Mactivity.app.
build_release() {
    xcodegen generate --quiet
    xcodebuild -project Mactivity.xcodeproj -scheme Mactivity -derivedDataPath "$1" \
        -destination 'platform=macOS,arch=arm64' -configuration Release -quiet build >/dev/null
}

# isolate_copy <app> <bundle id>: a measuring copy under its own bundle ID, so it has its own
# preferences. CFFIXED_USER_HOME redirects files but not preferences: under the real ID, a copy
# with an empty home sees none of this Mac's LaunchAgents and cuts them from the installed app's
# startup.knownItems, and the installed app then announces them as new (D-268). No widget
# extension either, so nothing registers with the system.
isolate_copy() {
    rm -rf "$1/Contents/PlugIns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $2" "$1/Contents/Info.plist"
    codesign -f -s - --deep "$1" >/dev/null 2>&1
}

# stop_copy <pid>: asks it to quit and waits, because it writes its preferences on the way out.
stop_copy() {
    kill "$1" 2>/dev/null || return 0
    for _ in 1 2 3 4 5 6 7 8; do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 1
    done
}

# forget_copy <app> <bundle id>: what isolate_copy's copy leaves behind outside the build folder.
forget_copy() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$1" 2>/dev/null || true
    defaults delete "$2" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$2.plist"
}

# project_setting <KEY>: a quoted build setting from project.yml, e.g. MARKETING_VERSION → 0.9.2.
# The first match wins; empty when the key isn't there.
project_setting() {
    sed -nE "s/^[[:space:]]*$1: \"([^\"]*)\".*/\\1/p" "$MACTIVITY_ROOT/project.yml" | head -1
}
