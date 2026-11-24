# Mactivity

One lightweight Mac app that does the jobs of several small utilities: activity monitoring, menu bar stats, disk space, login items, dev servers, sensors, and per-app volume. It groups every process under the app it belongs to, keeps a year of history, and tells you when an app misbehaves. Built in Apple's current design language for macOS 26 and 27, Apple silicon only.

- **Apps, not processes.** About 60 rows instead of 1,000, each with CPU, memory, Energy Impact, disk, network, and GPU. Rows always add up to the system totals. Get Info shows a process's arguments, open files, and sockets; each app's connections are one click away.
- **Memory of what happened.** A year of per-app history, scrubbable, with the top apps for any range and how they compare with the period before. An optional daily summary.
- **It tells you.** Notifications when an app hogs the CPU, keeps growing, or hammers the disk or network.
- **Menu bar.** An icon, a figure, a graph, or stacked figures, and a compact window with every metric.
- **Projects and Docker.** Dev servers found by listening port and project folder, with how long each has been idle, and Docker containers with their CPU and memory. Stop servers and containers, or restart a container; each asks first.
- **Storage.** A sunburst map of the disk, categories, a Developer lens for rebuildable caches, and the largest files. Move to Trash asks first and never deletes.
- **Startup.** Login items, launch agents, and daemons, grouped by app, with broken and unusual ones flagged. Your own launch agents can be turned off and back on.
- **Sensors.** Temperatures, fans, a year of battery health, and AirPods and other accessory batteries.
- **Security.** Protections on or off, which apps have which permission, system extensions, and what each browser extension can reach. Read-only. With Full Disk Access on; macOS 27 keeps camera, microphone, Automation and folder permissions from other apps, so those link to System Settings there.
- **Network interfaces.** What `ifconfig` shows, in plain words, with a hover explaining each fact.
- **Per-app audio (experimental).** Volume, mute, and output device per app, remembered between launches. Off until you turn it on in Settings.
- **Shortcuts, CLI, widgets.** Four Shortcuts actions, a read-only `mactivity` command-line tool, and small, medium, and large desktop widgets.
- **Light.** Under 0.2% of one core and under 30 MB of memory while it sits in the menu bar as an icon (M5 Pro, macOS 27).
- **Nothing leaves the Mac.** One network call on its own: the update check. Host-name lookups and the Homebrew vulnerability check happen only if you turn them on.

## Free and open source

Mactivity is free: no license key, no account, no subscription. The source is here under the [MIT license](LICENSE). Versions 1.0 to 1.9 were sold with a license key; that ended in late 2026 and the licensing code was removed.

## Install

Download the signed and notarized app from [mactivity.app/download](https://mactivity.app/download), for Apple silicon Macs on macOS 26 or later. It updates itself through Sparkle; what changed in each version is at [mactivity.app/changelog](https://mactivity.app/changelog).

With Homebrew: `brew install --cask mactivity/tap/mactivity`.

Found a bug? [Open an issue](https://github.com/Mactivity/mactivity/issues) with your Mac model, macOS version, and what happened just before the problem.

## Build

Requires Xcode 27 (macOS 27 SDK).

```bash
make setup   # xcodegen, swiftlint, swiftformat
make run     # generate the project, build, launch
make test    # package tests + hosted app tests
make lint
```

A Debug build is ad-hoc signed and needs no Apple account. `make release` archives, signs with Developer ID, notarizes, and staples a DMG; it needs your own `TEAM_ID` and `NOTARY_PROFILE` (see `scripts/release.sh` and `docs/APPLE-DEVELOPER.md`). The Sparkle feed and public key in `project.yml` are the official app's: change both if you ship a fork.

## Layout

`project.yml` (XcodeGen) is the source of truth for targets. The app target in `App/` is thin: nearly everything lives in the local package `Packages/MactivityKit`, one library target per area (Core, Sampling, Grouping, History, Alerts, Projects, Sensors, Audio, Export, Storage, Startup, Docker, PrivateAPIs, Simulated, UI). The read-only privileged helper is in `Helper/`.

## Docs

- `CLAUDE.md`: how the repo works and its rules.
- `docs/SPEC.md`: what the app is, feature by feature.
- `docs/releases/`: release notes for every version.
- `docs/localization/README.md`: how strings and the ten translations work.

Comments in the code cite decisions as `D-123`. Those are entries in a private decision log that isn't part of this repository; the comment itself says what was decided.

## License and credits

MIT, see [LICENSE](LICENSE). The name "Mactivity" and the app icon are not covered by the license: please give a fork its own name and icon.

Mactivity uses [GRDB](https://github.com/groue/GRDB.swift) for its history store and [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, both MIT. Parts of the SMC, sensor and accessory-battery readers are adapted from [Stats](https://github.com/exelban/stats) by exelban (MIT), credited in those files' headers.
