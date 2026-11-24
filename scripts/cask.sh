#!/bin/bash
# Writes the Homebrew cask for the current version from its DMG in dist/ (roadmap: install with
# Homebrew). `make cask` after `make release`; publishing it (a tap repo) is separate.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$MACTIVITY_ROOT"
VERSION="$(project_setting MARKETING_VERSION)"
DMG="$ROOT/dist/Mactivity-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "No $DMG. Run make release first." >&2; exit 1; }
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
OUT="$ROOT/packaging/homebrew/mactivity.rb"
cat >"$OUT" <<RUBY
cask "mactivity" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://mactivity.app/download/Mactivity-#{version}.dmg"
  name "Mactivity"
  desc "System monitor that groups every process under its app, with a year of history"
  homepage "https://mactivity.app/"

  livecheck do
    url "https://mactivity.app/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Mactivity.app"
  binary "#{appdir}/Mactivity.app/Contents/Helpers/mactivity"

  zap trash: [
    "~/Library/Application Support/Mactivity",
    "~/Library/Caches/app.mactivity.Mactivity",
    "~/Library/Group Containers/M48435UMZ2.app.mactivity",
    "~/Library/HTTPStorages/app.mactivity.Mactivity",
    "~/Library/Preferences/app.mactivity.Mactivity.plist",
    "~/Library/Saved Application State/app.mactivity.Mactivity.savedState",
  ]
end
RUBY
echo "Wrote $OUT for $VERSION ($SHA)."
