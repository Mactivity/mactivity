# CLAUDE.md — Mactivity

A native macOS system monitor that groups every process under the app it belongs to, keeps a year of history, alerts when an app misbehaves, and lives in the menu bar. Free and open source (MIT). Never name a rival product in site or marketing copy.

## Docs

- `docs/SPEC.md`: the product and technical spec. Section 6 is the technical approach, 10 the design bar, 12 distribution.
- `docs/releases/<version>.md`: release notes (`next.md` is the unreleased work). `docs/localization/README.md`: how strings and the ten languages work. `docs/APPLE-DEVELOPER.md`: signing and notarization setup.
- `docs/private/`: the maintainer's working notes, gitignored and not in the public repo. When the folder is on this Mac: `STATUS.md` is the current state (read it at the start of a session, update it at the end; replace old lines, don't append), `DECISIONS.md` is why things are the way they are (D-001 onward, newest last; **never read it whole, it is over 400 KB**: list titles with `grep -n '^## D-' docs/private/DECISIONS.md`, then read the one entry, and keep new entries under about ten lines), and `VERSIONS.md` is the plan. Nothing from this folder goes into tracked files, the website or release notes.
- Comments cite decisions as `D-123`. Without `docs/private/`, the comment itself is the record.

## Stack

- Swift 6 toolchain in **Swift 6 language mode**. Samplers are `actor`s; view models are `@MainActor @Observable`. Tests use Swift Testing, not XCTest.
- SwiftUI for all views, built against the **macOS 27 SDK**, using Liquid Glass and the native components it comes with (spec Section 10). AppKit only where SwiftUI can't do the job: the menu bar item's figure, graph and stacked modes, `NSRunningApplication`, `NSWorkspace`.
- Swift Charts for history.
- **Deployment target macOS 26 Tahoe, Apple silicon only.** Anything that needs a 27-only API gets an `if #available(macOS 27, *)` with a 26 fallback.
- **Not sandboxed.** Developer ID and notarization, distributed outside the App Store.
- The app icon is a layered Icon Composer `.icon` asset, not a flat PNG set.
- XcodeGen generates the `.xcodeproj` from `project.yml`; the `.xcodeproj` is gitignored.

## Commands

```
make build       # generate the project, then a Debug build
make run         # build, then open the app
make test        # package tests, the layout tests again with Larger figures, then the app target's tests
make test-live   # package tests plus the ones that use this Mac: hardware samplers, Core Audio, network, on-device model
make test-pseudo # layout tests with every string doubled; run after changing layout or strings
make sync-strings # merge new strings into the String Catalogs; run after changing strings
make lint        # swiftlint, swiftformat --lint, and the strings check
make fmt         # swiftformat .
make measure     # idle CPU and memory of a Release build (S=seconds, MENUBAR=…, CLOSED=1 after opening and closing the window)
make measure-compare A=<rev> B=<rev>  # two builds idle side by side under the same load
make size        # install-size budget
make clean       # remove build products and the generated .xcodeproj
```

The Makefile has the rest (release, site, media, snapshots), each with a comment. If a target doesn't exist yet, add it rather than running the raw command.

## Layout

```
project.yml               XcodeGen spec (single source of truth for targets)
App/                      App target: entry point, AppDelegate, windows, menu bar, Info.plist, entitlements, Assets
AppTests/                 Tests hosted in the app target
Helper/                   Privileged XPC daemon. Read-only. Registered from Settings in signed builds.
Widgets/                  WidgetKit extension
Packages/MactivityKit/    One local Swift package, many library targets:
  Sources/Core/           Models, units, formatting, and the DataSource protocols. No I/O. No imports beyond Foundation.
  Sources/Sampling/       Real system samplers: CPU, Memory, Disk, Network, GPU, Battery, Processes
  Sources/Grouping/       Process → app resolution, app identity, the snapshot pipeline
  Sources/History/        SQLite store (GRDB), rollups, retention, queries
  Sources/Alerts/         Rule engine + UNUserNotificationCenter delivery
  Sources/{Projects,Sensors,Audio,Storage,Startup,Docker,Export}/   One feature area each, as named
  Sources/Protections/    The Security page's readers
  Sources/Readouts/       Shortcuts, widget and CLI summaries
  Sources/MactivityCLI/   The read-only `mactivity` command
  Sources/PrivateAPIs/    Every non-public symbol lives here and nowhere else (rule 2)
  Sources/CDriveHealth/   C shim for drive health
  Sources/Simulated/      Fake implementations of every Core protocol. Used by previews, tests, and "Simulated data" mode.
  Sources/UI/             Views shared by the main window and the menu bar window
  Tests/                  One test target per source target, fixtures in Tests/Fixtures/
scripts/                  What the Make targets run
website/                  mactivity.app, published by `make site`
packaging/homebrew/       The Homebrew cask
docs/                     See Docs above
```

Dependency direction is one way: `UI → (History, Alerts, Projects, Sensors, …) → Grouping → Sampling → Core`. `Core` imports nothing. `Simulated` imports only `Core`. If you need to break this, log it in the decision log first.

## Rules

1. **Protocol first.** Every data source is a protocol in `Core` (e.g. `CPUSource`, `ProcessSource`, `SensorSource`), with a real implementation and a `Simulated` one. The UI only ever sees the protocol.
2. **Private APIs are quarantined.** Anything not in a public Apple header goes in `Sources/PrivateAPIs`, wrapped in a Swift function with a doc comment naming the symbol, the framework, and what breaks if Apple removes it. Every wrapper has a public-API fallback, even a degraded one, and a unit test that exercises the fallback.
3. **Nothing leaves the Mac.** No analytics, no crash reporting services, no telemetry. The only network call is the update check (Sparkle), plus two that are off by default behind Settings → Privacy toggles: reverse DNS for one address when the user clicks Look Up Name (D-051), and the vulnerability check (`brew vulns`, Homebrew → OSV.dev, D-252). If you write a `URLSession` call anywhere, stop and ask.
4. **Never terminate anything without a confirmation UI.** `terminate`, `forceTerminate`, `kill`, and the Projects "Stop" action all go through one `ConfirmedAction` path in `UI`. No exceptions, including tests.
5. **Performance budget is a feature.** Idle (no window open): sample every 10 s, under 0.25% of one core (D-266), physical footprint under 35 MB if the window was never opened and under 75 MB once it has been opened and closed (D-268). Visible: sample every 1 s. The app bundle stays under 50 MB and history under about 60 MB at a year (D-058, D-089). Don't add always-on polling. Measure when a change adds work to the sampling path, or at a release, and record the numbers.
6. **Approved dependencies:** GRDB (SQLite) and Sparkle (updates). Ask before adding anything else. Prefer Apple frameworks.
7. **Reference code:** Stats by exelban (MIT) is a good reference for SMC, HID sensors, and Bluetooth battery reading. Adapt with attribution in the file header; don't paste whole files. Do **not** take code from Background Music (GPL) or anything without a permissive license.
8. **Native components first.** Use the standard SwiftUI component for the job (`NavigationSplitView`, `List`, `Form`, `Table`, `Chart`, `MenuBarExtra`, `Settings`) and style it with the tokens in `Sources/UI/Tokens.swift`. Every screen must look right with Reduce Transparency and Increase Contrast turned on, in light and dark mode.
9. **Every metric has a fixture test.** Grouping, rollups, alert rules, and project detection are pure functions over sample data. Test them with fixtures in `Tests/Fixtures/`, not with the live machine.
10. **No force unwraps outside tests. No `try!`. No `print`:** use `os.Logger` with a subsystem per package.
11. **Ask before deviating from the spec.** If the spec is wrong, say so and propose the change. Log accepted changes in the decision log.

## Product rules

- **Free, forever.** No license key, no account, no paid tier, no trial. Don't add billing, activation or any gate on features.
- **No AI that costs per use.** On-device only, opt-in, never the headline (D-161). Ask before proposing an AI feature.
- **Nothing private in the repo.** It is public: no account IDs, personal email addresses, credentials, plans or business notes in tracked files. Those live in `docs/private/` or outside the repo.

## Releasing

1. `make bump V=x`, then write the notes in `docs/releases/x.md`, one `- ` line each.
2. `make release`: lint, tests, sign, notarize, DMG, the signed appcast entry and the Homebrew cask.
3. Check `git diff website/`, ask the maintainer, then `make site` (it needs the Cloudflare account ID in the environment, see `scripts/site.sh`).
4. Copy `packaging/homebrew/mactivity.rb` to the tap's `Casks/`, commit there and push (D-173).

**The update feed must stay signed (D-256).** Never hand-edit `website/appcast.xml`; if it changes, re-sign it with `sign_update --account mactivity`, or 1.7.1 and later stop updating.

## Session habits

- Start: read `docs/private/STATUS.md` if it's there and say what you're picking up. Run `make build` before changing code.
- During: commit at every green build with a message that says what works, not what changed.
- End: update `docs/private/STATUS.md` if it's there (what's live, what's unreleased, what's next, current performance numbers), with open questions at the top.
