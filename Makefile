# Mactivity. Run `make setup` once, then `make run`.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT      := Mactivity.xcodeproj
SCHEME       := Mactivity
DERIVED      := build/DerivedData.noindex
APP          := $(DERIVED)/Build/Products/Debug/Mactivity.app
PACKAGE      := Packages/MactivityKit
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'
# xcbeautify/xcpretty are optional; fall back to quiet raw output.
PRETTY       := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: brand cask demo-video media measure-compare setup gen build run run-background run-pseudo run-lang sync-strings check-strings test-pseudo test-larger measure size beta site site-preview test test-package test-live test-app snapshots lint fmt clean release apple-setup site-shots bump

setup:
	brew install xcodegen swiftlint swiftformat
	@xcodebuild -version
	@xcrun --show-sdk-version --sdk macosx | grep -Eq '^2[7-9]' || { echo "Need the macOS 27 SDK (Xcode 27)."; exit 1; }

gen:
	xcodegen generate --quiet

# Always regenerate: new files in App/, Helper/, or Widgets/ only join the project this way.
$(PROJECT): gen

build: gen
	$(XCODEBUILD) -configuration Debug -quiet build | $(PRETTY)

# Quit any running copy and wait for it to exit: opening while it's still shutting down makes
# Launch Services fail with error -600.
define quit-running
	@pkill -x Mactivity 2>/dev/null || true
	@for i in $$(seq 1 20); do pgrep -x Mactivity >/dev/null || break; sleep 0.25; done
endef

run: build
	$(quit-running)
	open "$(APP)"

# Menu bar only, the idle state the performance budget is measured in.
run-background: build
	$(quit-running)
	open "$(APP)" --args --background

# Pseudo-localized: every localized string doubled (Apple's NSDoubleLocalizedStrings), about as
# long as German or Finnish, to find clipped and overflowing text (docs/localization/README.md).
run-pseudo: build
	$(quit-running)
	open "$(APP)" --args -NSDoubleLocalizedStrings YES -AppleLanguages "(en)"

# In another language, once its translations are in the catalogs: make run-lang L=de
run-lang: build
	@test -n "$(L)" || { echo "Usage: make run-lang L=de"; exit 1; }
	$(quit-running)
	open "$(APP)" --args -AppleLanguages "($(L))"

# Merges the strings the compiler extracted into the String Catalogs; run after changing strings.
sync-strings: build
	scripts/strings.py sync

# SwiftUI literals in the package that would skip its catalog (part of lint).
check-strings:
	scripts/check-strings.sh
	scripts/pin-packages.sh --check

# CPU and memory of a Release build. S=seconds (default 300). TAB=cpu (or overview, memory, …)
# measures with the main window open on that tab; without it, idle against the budget.
# CLOSED=1 opens the window, closes it after 30 s and measures what's left, the second budget (D-268).
# MENUBAR=figure|graph|stacked with METRIC=… or STACKED=cpu,memory measures another menu bar mode.
measure:
	scripts/measure.sh $(or $(S),300) $(TAB)

# A one-minute demo video on simulated data, filmed from the app's own window (D-124)
demo-video:
	scripts/demo-video.sh

# Two builds idle side by side, so both see the same load: make measure-compare A=<rev> B=<rev> S=300
measure-compare:
	scripts/measure-compare.sh $(A) $(or $(B),HEAD) $(or $(S),300)

# The website plus current installers, to a Cloudflare Worker with static assets (D-076);
# site-preview serves it locally.
site:
	scripts/site.sh

# Website screenshots from the real app, simulated data, light and dark (needs Screen Recording).
site-shots:
	scripts/site-shots.sh

# Marketing media library: screenshots, clips, cards and captions, into MarketingCollateral/ (gitignored)
# (OUT=…, ONLY=shots|clips|tour|cards, MENUBAR=1). Needs Screen Recording, like site-shots.
media:
	scripts/media.sh

site-preview:
	scripts/site.sh preview

# Tester build: Release, ad-hoc signed, zipped into dist/ (D-073).
beta:
	scripts/beta.sh

# Release app size against the install budget (50 MB); removes its build afterwards.
size:
	scripts/size.sh

test: test-package test-larger test-app

# Swift Testing only (no test uses XCTest: its runner reported "Executed 0 tests" for all 18
# targets), and without the *RenderTests suites, which draw screenshots for `make snapshots`
# rather than check anything. Tests that read this Mac's hardware, play with its audio, fetch over
# the network or run the on-device model wait for `make test-live`.
SWIFT_TEST := swift test --disable-xctest
test-package:
	cd $(PACKAGE) && $(SWIFT_TEST) --skip RenderTests

# Everything above plus the live tests: the samplers on this Mac's hardware, Core Audio, the
# NetworkStatistics ledger (curl fetches a page), the launchd audit, and the on-device model.
test-live:
	cd $(PACKAGE) && MACTIVITY_LIVE_TESTS=1 $(SWIFT_TEST) --skip RenderTests

test-app: gen
	$(XCODEBUILD) -configuration Debug -quiet test | $(PRETTY)

# The layout tests again with every localized string doubled: the main window's fit, the menu
# bar window, and the menu bar item's fixed widths (docs/localization/README.md).
PSEUDO_TESTS := WindowFitTests|OnboardingFitTests|SettingsFitTests|MenuBarWindowLayoutTests|MenuBarFigureTests/widths|MenuBarLayoutTests/columnCoversLabel
test-pseudo:
	cd $(PACKAGE) && MACTIVITY_PSEUDO_LOCALIZATION=1 $(SWIFT_TEST) --filter '$(PSEUDO_TESTS)'

# The layout tests again with Settings → Customize's Larger figures on (D-276): in their own
# process, since the setting is shared by everything drawn. Part of `make test`.
LARGER_TESTS := WindowFitTests|SettingsFitTests|MenuBarWindowLayoutTests|LargerFiguresProofTests
test-larger:
	cd $(PACKAGE) && MACTIVITY_LARGER_FIGURES=1 $(SWIFT_TEST) --filter '$(LARGER_TESTS)'

# Light and dark renders of content views into docs/screenshots/$(M) (default M0).
# FILTER picks another render suite, e.g. `make snapshots M=menubar FILTER=MenuBarRenderTests`, or
# `make snapshots M=charts FILTER=ChartRenderTests` for Overview, the CPU tab, and History with 30
# days of fixture history.
M ?= M0
FILTER ?= SnapshotRenderTests
snapshots:
	mkdir -p docs/screenshots/$(M)
	cd $(PACKAGE) && MACTIVITY_SNAPSHOT_DIR="$(CURDIR)/docs/screenshots/$(M)" $(SWIFT_TEST) --filter $(FILTER)

lint:
	swiftlint lint --strict --quiet
	swiftformat --lint . --quiet
	scripts/check-strings.sh

fmt:
	swiftformat . --quiet

clean:
	rm -rf build $(PROJECT) $(PACKAGE)/.build $(PACKAGE)/.swiftpm

# One-time Developer ID, notarization and Sparkle setup, from Terminal (docs/APPLE-DEVELOPER.md).
apple-setup:
	scripts/apple-setup.sh

# Next version: make bump V=0.9.1 (raises the build number Sparkle compares too).
bump:
	scripts/bump.sh "$(V)"

# Logo images from the release build's icon (docs/brand).
brand:
	swift scripts/brand-images.swift "$(CURDIR)/build/Release.noindex/export/Mactivity.app" docs/brand

# The Homebrew cask for the current version's DMG (packaging/homebrew/mactivity.rb).
cask:
	scripts/cask.sh

# Archive, Developer ID sign, notarize, staple, DMG. Needs make apple-setup once; TEAM_ID and
# NOTARY_PROFILE override what it set up (see the script).
# Lint and every test on this Mac first.
release: lint test
	scripts/release.sh
