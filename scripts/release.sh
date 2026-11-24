#!/bin/bash
# Archive, sign with Developer ID, notarize, staple, and package a DMG (spec 11, M8).
#
# Needs, once: `make apple-setup` (docs/APPLE-DEVELOPER.md). That leaves a "Developer ID Application"
# certificate in the login keychain, the team ID in project.yml (MACTIVITY_RELEASE_TEAM), and a
# notarytool keychain profile named "mactivity". TEAM_ID and NOTARY_PROFILE override them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$MACTIVITY_ROOT"
TEAM_ID="${TEAM_ID:-$(project_setting MACTIVITY_RELEASE_TEAM)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mactivity}"
[[ -n "$TEAM_ID" ]] || { echo "No team ID. Run make apple-setup first (docs/APPLE-DEVELOPER.md)." >&2; exit 1; }
# Working files (archive, export, derived data) stay out of Spotlight in a .noindex folder; the
# finished DMG is copied to dist/, next to the betas, where `make site` picks it up.
OUT="$ROOT/build/Release.noindex"
ARCHIVE="$OUT/Mactivity.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Mactivity.app"

cd "$ROOT"
BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
if grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" website/appcast.xml && [[ "${REPLACE:-}" != "1" ]]; then
    echo "Build $BUILD_NUMBER is already in website/appcast.xml. Run make bump V=... for a new version," >&2
    echo "or REPLACE=1 make release to rebuild this one (only if it isn't published yet)." >&2
    exit 1
fi

# The team's valid Developer ID certificate that expires last, by SHA-1. Old (pre-G2) and G2
# certificates share a name, so signing by name would be ambiguous once both are in the keychain.
IDENTITY=""
LATEST=0
for HASH in $(security find-identity -v -p codesigning \
  | sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .*\($TEAM_ID\)\"$/\1/p"); do
  END="$(security find-certificate -a -Z -p -c "Developer ID Application" \
    | awk -v h="$HASH" '/^SHA-1 hash:/ { take = ($3 == h) } take && /BEGIN CERT/, take && /END CERT/' \
    | /usr/bin/openssl x509 -noout -enddate | cut -d= -f2)"
  EPOCH="$(date -j -f "%b %e %T %Y %Z" "$END" +%s)"
  if ((EPOCH > LATEST)); then
    LATEST=$EPOCH
    IDENTITY=$HASH
  fi
done
[[ -n "$IDENTITY" ]] || { echo "No valid Developer ID Application certificate for team $TEAM_ID. Run make apple-setup." >&2; exit 1; }
echo "→ Signing with $IDENTITY (Developer ID, team $TEAM_ID, expires $(date -r "$LATEST" +%Y-%m-%d))"

rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet

echo "→ Archiving"
xcodebuild -project Mactivity.xcodeproj -scheme Mactivity -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  -quiet archive

echo "→ Exporting"
sed -e "s/__TEAM_ID__/$TEAM_ID/" -e "s/__IDENTITY__/$IDENTITY/" scripts/ExportOptions.plist > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" -quiet

codesign --verify --deep --strict --verbose=2 "$APP"
scripts/check-hardening.sh "$APP"
scripts/size.sh 50 "$APP"
codesign -d --entitlements - "$APP" | grep -q "app-sandbox" && echo "(sandbox key present and false, as intended)"

echo "→ Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Mactivity.zip"
xcrun notarytool submit "$OUT/Mactivity.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
DMG="$OUT/Mactivity-$VERSION.dmg"
echo "→ Building $DMG"
# The drag-to-install window: Mactivity, an arrow, and Applications over a background (D-075).
scripts/dmg.sh "$APP" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "→ Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

mkdir -p "$ROOT/dist"
cp "$DMG" "$ROOT/dist/"
DMG="$ROOT/dist/$(basename "$DMG")"
echo "✓ $DMG is signed, notarized, and stapled."

# The update feed, the download links and the page sizes (review, then make site).
scripts/publish-version.sh "$DMG"
# The Homebrew cask for this DMG; copy it to the tap (github.com/mactivity/homebrew-tap) when publishing.
scripts/cask.sh
