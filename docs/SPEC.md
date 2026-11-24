# Mactivity — Product and Technical Spec

Status: built and shipping (1.x). Where a decision changed the spec, a private decision log has the entry; the `D-nnn` numbers here and in the code refer to it. Mactivity is free and open source since late 2026 (Section 12).

Sections 1–8 describe the baseline: parity with the app that served as the feature reference. Section 9 lists the expansions beyond it; most are now built. Section 10 is the design direction and is not optional: Mactivity is built in Apple's current design language, and it has to be beautiful. Section 11 is the build order. Section 12 is distribution: free and open source.

Platform decisions, made: **macOS 27 SDK, deployment target macOS 26, Apple silicon only.** Intel and older versions of macOS aren't supported, on purpose (see 6.0).

Change note, 2026-09-26: Section 1 and Section 2 now describe Mactivity as one lightweight app that does the jobs of several single-purpose utilities No feature, section number, or rule changed.

---

## 1. What it is

One lightweight app for the everyday jobs of looking after a Mac, instead of separate apps for activity monitoring, menu bar stats, disk space, login items, dev servers, sensors, and per-app volume (experimental, D-054). It lives in the menu bar and answers everyday questions in one line each: what is using my memory, what is draining the battery, what is slowing this Mac down, what did I leave running, what is filling my disk, and what starts when I log in.

Three ideas make it different from Activity Monitor:

1. **Apps, not processes.** Every helper process is rolled up under the app that launched it. About 60 rows instead of about 1,000. One figure per app for CPU, memory, energy, disk, and network.
2. **Memory of what happened.** A year of per-app history, so "why was my Mac slow at 2pm" has an answer.
3. **It tells you.** A notification when an app hogs the CPU, keeps growing in memory, or hammers the disk or network.

One idea makes it different from a folder of small utilities:

4. **One app, one budget.** Each job it takes on (projects and Docker containers, the storage map, the startup audit, sensors, per-app audio, Shortcuts, the CLI, widgets) shares one process, one sampler, and one history store, and anything that stops, disables, or trashes something asks first. All of it together stays inside the idle budget in Section 8.

Everything stays on the Mac. No account, no analytics.

## 2. Who it's for

Developers and power users on Apple silicon Macs running macOS 26 or 27 who have Activity Monitor open more than they'd like, run dev servers they forget about, and want to know what their machine is doing without reading a thousand rows. People who have a menu bar full of small utilities, one per job, and would rather have one app that does those jobs well. People who want a tool that looks like Apple made it.

## 3. Non-goals

- Not a cleaner, optimizer, or "free up RAM" button. We show and we stop things on request; we don't tune.
- Not a remote monitoring or fleet tool (unless chosen in Section 9).
- Not a process sampler/debugger. Activity Monitor's "Sample Process" and "Spindump" stay in Activity Monitor.
- Not on the Mac App Store. The sandbox forbids reading other apps' processes.
- No cloud sync, no accounts, no telemetry, ever.

## 4. Surfaces

### 4.1 Menu bar item

Always present. Four display modes, user picks one, plus which metric(s) to show:

| Mode    | Shows                                           |
|---------|-------------------------------------------------|
| Icon    | App icon only; turns into a warning glyph under strain |
| Figure  | One metric as text, e.g. `27%` or `12 kB/s`     |
| Graph   | Small sparkline of one metric, last ~2 minutes  |
| Stacked | Up to four columns, each a tiny label over its value, e.g. `CPU 27%` beside `MEM 82%` (D-067) |

Metrics available: CPU, memory, GPU, network, temperature, battery.

"Under strain" is a defined state (Section 7.3), not a vibe.

### 4.2 Compact view (menu bar window)

Click the menu bar item. A glass `MenuBarExtra` window, no scrolling on a 13-inch screen:

- **Overview:** uptime; one line per metric (CPU %, memory used/total, network up/down, disk free, GPU %, battery % and time); "Busiest right now" — top 3 apps.
- **One tab per metric** (CPU, GPU, Memory, Disk, Network, Battery, Projects; order per D-082): the headline figure, 3–4 secondary figures, and the top 5 apps for that metric.
- Footer: "Open Mactivity" (opens the main window on the same tab) and "Quit".

### 4.3 Main window

`NavigationSplitView` with a sidebar: Overview, then Metrics (CPU · Memory · Disk · Network · GPU · Battery), then Projects, Alerts, History. Unified toolbar holds the range picker and search. Component details in 10.2.

Every metric tab has the same skeleton, built from one pattern:

1. **Headline card** — the big number, a status word (Normal / Elevated / Critical), and a live sparkline.
2. **Secondary figures** — 3–6 small stats.
3. **History strip** — time range picker: 12 h · 24 h · 7 d · 30 d · 90 d · 1 y (D-089). Chart of the metric over that range, with the top apps for the range beneath it.
4. **App list** — every app, sorted by this metric, with process count and the figure. Expand a row to see the individual processes. Right-click or swipe for Quit / Force Quit.

**Overview tab** is a grid of the headline cards from each metric, plus "Memory by type" and "Memory by app" donuts, and "Power by app".

**Projects tab** is different (Section 5.7).

### 4.4 Notifications

Standard macOS notifications via `UNUserNotificationCenter`. Title is the app name and what it's doing; body is the evidence. Example: "Slack keeps using more memory — Up 1.4 GB in an hour, now 3.3 GB." Clicking opens the main window on the relevant tab with that app highlighted.

### 4.5 Settings

- General: launch at login, sample rate while visible, appearance (system/light/dark)
- Menu bar: mode, metrics, order
- Alerts: per-rule thresholds and on/off, per-app mute list, quiet hours
- History: retention (7, 14, 30, 90 days or a year; default a year, D-089), database size, "Delete history"
- Privacy: shows the one network call the app makes on its own, plus the opt-in host-name lookup (D-051) and vulnerability check (D-252), and nothing else
- Helper: enable/disable the privileged helper (Section 6.9)

## 5. Features (parity)

### 5.1 Processes grouped by app

Every process is assigned to exactly one **app identity**:

- Bundled apps: the bundle ID and icon of the app that launched the process.
- Terminal-launched processes: grouped under the terminal app (Terminal, iTerm, Warp, Ghostty…), as in "Terminal: 49 processes".
- System daemons: grouped under "macOS" (shown as the System row), only visible when the helper is enabled or the process is readable.
- Anything unresolvable: grouped under "Other", never hidden.

Each app row shows: icon, name, process count, and the figure for the current tab. Expanding shows processes with PID and figure. Totals are the sum of the processes; we never double count.

### 5.2 Per-app figures

Per app, per sample: CPU % (user+system), memory (physical footprint, same number Activity Monitor calls "Memory"), energy (mW, Apple silicon), disk read/write bytes/s, network down/up bytes/s, GPU % (see 6.6 — may be system-only in v1).

### 5.3 A year of history

Per app and system-wide, every metric, six ranges: 12 h, 24 h, 7 d, 30 d, 90 d, 1 y. "Which apps used the most" for any range. One SQLite file, about 40–60 MB at a year (D-089). Section 6.7 has the tiers.

### 5.4 Alerts for misbehaving apps

Four rules, on by default, thresholds editable:

| Rule            | Default trigger                                         |
|-----------------|---------------------------------------------------------|
| High CPU        | ≥ 70% average for 10 minutes                            |
| Growing memory  | +1 GB or more over 60 minutes, and still growing        |
| Heavy disk      | ≥ 50 MB/s written, sustained 5 minutes                  |
| Heavy network   | ≥ 10 MB/s in either direction, sustained 5 minutes      |

Each rule has a cooldown (default 60 min per app per rule), respects the per-app mute list and quiet hours, and by default doesn't fire for the frontmost app doing something obvious (e.g. Xcode compiling). That exemption is a setting, on by default. Open question 5 in Section 13.

Four more rules are about the Mac rather than a running app's figures (D-099). They're checked every 10 minutes, each with its own repeat interval:

| Rule                   | Default trigger                                          | Repeats after |
|------------------------|----------------------------------------------------------|---------------|
| Accessory battery low  | An accessory at 15% or less                              | 12 hours      |
| Disk filling up        | The startup disk full within 14 days at its rate         | 3 days        |
| App keeps crashing     | 3 or more crash reports for one app in a day             | 24 hours      |
| Mac awake all night    | Recording from 1 to 5 am with under an hour asleep       | 20 hours      |

### 5.5 Dev servers and open ports, by project

Processes that hold a listening TCP port are grouped by the **project folder** they run in. Each project shows: name (folder name), runtime (node, python, go, ruby, java, bun, deno, rust, other), port(s), memory, uptime, and an activity state: **working** / **idle N min** / **barely used** (up ≥ 1 day, CPU time under a threshold).

The tab header sums it up: "5 dev servers · 4 idle · stopping them frees 1.37 GB and ports 3000, 4321, 4322, 8000." with a **Stop All…** button. Stop always confirms first, one dialog listing what will be stopped. After stopping: a toast, "storefront-web stopped. 458 MB and port 4322 are free."

### 5.6 Temperatures, fans, peripheral batteries

CPU and GPU temperature, fan speed(s) where present, and battery % for AirPods, Magic Mouse, Magic Keyboard, and Magic Trackpad. Shown in the Battery tab and available as a menu bar metric.

### 5.7 Volume control per app

Stretch (M10). A list of apps currently playing audio with a slider each. Nothing recorded, nothing stored. Section 6.10 has the approach.

### 5.8 Quit and force quit

From any app row or process row. Quit sends the normal termination; Force Quit sends SIGKILL. Always a confirmation: "Quit Google Chrome? 96 processes will close." Root-owned processes need the helper and say so.

### 5.9 Export

- **Share image** (D-092): Overview's six headline cards with their sparklines, three by two, and a footer with the app, the Mac model and chip, and the time. 900 pt wide at @2x, in the window's appearance. The toolbar's Share menu offers **Share Image** (the system Share menu: Messages, Mail, AirDrop…), **Copy Image**, and **Save Image to Downloads** (named like a screenshot, with a timestamp).

### 5.10 Launch at login, updates, privacy

- Launch at login via `SMAppService.mainApp`.
- Updates via Sparkle, signed appcast, checked at most daily.
- Privacy page in Settings lists exactly what goes over the network: the update check. That's the whole list, apart from two things that are off until the user turns them on: host-name lookups in Get Info, which send one address per click (D-051), and the Homebrew vulnerability check (D-252).

## 6. Technical approach

This section is the part most likely to be wrong in details as SDKs move. Verify against the current macOS SDK before implementing each subsystem, and log corrections in the decision log.

### 6.0 Platform

- Build with the macOS 27 SDK. Deployment target macOS 26 Tahoe. arm64 only.
- Why not Intel: macOS 27 dropped it, Tahoe is the last release that runs on it, and Intel needs its own SMC key tables, has no `ri_energy_nj`, and has a different GPU path. That's weeks of work for a shrinking base.
- Why not macOS 27 minimum: Liquid Glass and the components in Section 10 shipped in 26, so 26 gets us the design without cutting off everyone who hasn't upgraded yet. Anything 27-only sits behind `if #available(macOS 27, *)` with a 26 fallback. Revisit for v2.
- Verify before M0: macOS 27 reportedly changes how third-party menu bar item icons show by default. If true, the onboarding flow has to tell the user how to make Mactivity visible, and the menu bar "figure" mode may matter more than "icon" mode.

### 6.1 Process enumeration and per-process metrics (public APIs)

- `proc_listallpids` / `proc_listpids` for the PID list every tick.
- `proc_pidinfo(PROC_PIDTBSDINFO)` → name, ppid, uid, start time.
- `proc_pidinfo(PROC_PIDTASKINFO)` → user/system CPU time, resident size, thread count.
- `proc_pid_rusage(RUSAGE_INFO_V6)` → `ri_phys_footprint` (the "Memory" number), `ri_diskio_bytesread` / `ri_diskio_byteswritten`, `ri_logical_writes`, `ri_energy_nj` (nJ, Apple silicon; delta over time → mW). Not `ri_billed_energy`, which only counts energy billed to the process by others and reads 0 for a busy process (D-109).
- `proc_pidpath` → executable path, used for app resolution and runtime detection.
- CPU % = delta of (user + system time) / wall time / core count, same as Activity Monitor.

**Limit:** these calls succeed for processes owned by the current user. Root and other-user processes return partial data or `EPERM`. That's what the helper is for (6.9). Without it we show the user's processes and a "System" row with the system-wide remainder (system total minus the sum of what we can see), clearly labeled.

### 6.2 Process → app resolution

Order of resolution, first match wins:

1. `responsibility_get_pid_responsible_for_pid(pid)` — **private**, libquarantine. Returns the "responsible" PID that Activity Monitor uses for its app grouping. Lives in `PrivateAPIs`. Fallback: step 2.
2. Walk `ppid` up the tree until a PID matches an `NSRunningApplication` (bundle ID + icon come free), or `launchd` (pid 1) is reached.
3. If the executable path contains `.app/`, take the outermost `.app` bundle and read its `Info.plist`.
4. Terminal heuristic: if the nearest ancestor with a bundle is a known terminal, group under it.
5. Otherwise "Other", keyed by executable name.

Cache app identity by (bundle path, mtime). Icons via `NSWorkspace.shared.icon(forFile:)`, cached at 32 pt and 64 pt.

### 6.3 System-wide CPU and memory

- CPU: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per core; P/E core split from `sysctl hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu`. Load average: `getloadavg`.
- Memory: `host_statistics64(HOST_VM_INFO64)`. App memory = `internal_page_count − purgeable_count`; Wired = `wire_count`; Compressed = `compressor_page_count`; Cached files = `external_page_count + purgeable_count`. Swap: `sysctl vm.swapusage`. Pressure: `sysctl kern.memorystatus_level` and `DispatchSource.makeMemoryPressureSource`.

### 6.4 Disk

- Volumes and free space: `FileManager.default.mountedVolumeURLs` + resource values.
- System-wide read/write throughput: IORegistry `IOBlockStorageDriver` → `Statistics` → "Bytes (Read)" / "Bytes (Write)", delta per tick.
- Per app: from 6.1 rusage deltas. "Written today" is a sum over history.

### 6.5 Network

- System-wide: `getifaddrs`, `AF_LINK` entries, `ifi_ibytes` / `ifi_obytes` per interface, delta per tick. Active interface via `SCNetworkReachability` / `nw_path_monitor`.
- **Per app: there is no public API.** Two options, decide in M3 with a spike:
  - (a) `NetworkStatistics.framework` (private, `NStatManager*`), which is what `nettop` uses. Well-trodden by other monitors, brittle across releases. Goes in `PrivateAPIs`.
  - (b) Socket enumeration via `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` gives connections per process but **not byte counts**; usable for "which apps are talking to the network" and for Section 9's connections feature, not for kB/s.
  - Fallback if (a) breaks: show system-wide throughput and per-app connection counts, label the per-app rate as unavailable.

### 6.6 GPU

- System-wide utilization and memory: IORegistry `IOAccelerator` entries → `PerformanceStatistics` → "Device Utilization %", "In use system memory". GPU name from the same entry or `sysctl machdep.cpu.brand_string` for the SoC.
- **Per app:** Activity Monitor's "% GPU" column comes from per-client accelerator statistics in IORegistry (Apple silicon). Spike this in M3: enumerate accelerator client entries and look for a PID-keyed utilization figure. If it isn't reliable, v1 ships GPU system-wide only, and the GPU tab's app list is hidden with a note in the decision log.

### 6.7 History store

GRDB over one SQLite file at `~/Library/Application Support/Mactivity/history.sqlite`, WAL mode.

Three tiers, one row per (timestamp, app) with all metrics as columns:

| Tier      | Resolution | Retained | Where      |
|-----------|-----------|----------|------------|
| Live ring | 10 s idle, 1 s visible | 60 min   | In memory  |
| Minute    | 1 min avg/max | 48 h  | SQLite     |
| Quarter   | 15 min avg/max | 30 d (less if retention is shorter) | SQLite     |
| Hour      | 1 h avg/max | the retention setting, default a year (D-089) | SQLite     |
| Accessory batteries | a reading when a level moves or hourly | the retention setting (D-094) | SQLite |
| Sleep and wake | each event, with the wake reason | the retention setting (D-096) | SQLite |
| Time in front | each stretch an app was frontmost and in use | the retention setting (D-098) | SQLite |

Rollups run every minute (ring → minute), every 15 minutes (minute → quarter) and every hour (quarter → hour). Ranges up to 24 h read minutes, 7 d and 30 d quarters, 90 d and 1 y hours. Retention runs hourly. System-wide rows use a reserved app ID. Size estimate at 60 apps: ~170 k rows per SQLite tier, well under 100 MB.

Queries the UI needs, each a single function in `History`: series(metric, app?, range), topApps(metric, range, n), totals(metric, range) for "written today" / "downloaded this session".

### 6.8 Alerts engine

Pure function: `evaluate(rules, ring, minuteTier, now) → [Alert]`. Runs every sample. State (last fired per app+rule, current streak) lives in a small `alert_state` table so it survives relaunch. Delivery is a separate `AlertDeliverer` protocol so tests never touch `UNUserNotificationCenter`.

### 6.9 Privileged helper (M9, optional, off by default)

A LaunchDaemon bundled at `Contents/Library/LaunchDaemons`, registered with `SMAppService.daemon(plistName:)`, talking XPC. The user enables it in Settings and approves it in System Settings → Login Items. It exposes one method: `sample() -> [ProcessSample]` for processes the app can't read itself. It is read-only, takes no other commands, and exits when the app has been gone for 10 seconds. Code-signing requirements pinned on both sides of the XPC connection.

### 6.10 Sensors

- Apple silicon temperatures: `IOHIDEventSystemClient` (private) matching temperature sensors (usage page `0xFF00`, usage `5`), read as HID events. Goes in `PrivateAPIs`.
- SMC (fans, some temps): `IOServiceOpen` on `AppleSMC`, `SMCReadKey` with the usual key format. Fan keys `F0Ac`, `F1Ac`, `FNum`. Key sets differ per SoC generation (M1 through M5); ship a table per family and a "discover keys" debug command. Fanless Macs show no fan section at all, not a zero.
- Battery: `IOPSCopyPowerSourcesInfo` for %, time remaining, source; `AppleSmartBattery` IORegistry entry for cycle count, max capacity %, temperature, and amperage × voltage → power draw in W.
- Peripheral batteries: IORegistry `BatteryPercent` on HID service entries (Magic devices); AirPods from Bluetooth device properties. Stats (MIT) has working code for both — reference it, don't paste it.

### 6.11 Per-app volume (M10)

Preferred: **Core Audio process taps** (`AudioHardwareCreateProcessTap`, macOS 14.2+, public). Tap the process with mute-when-tapped, scale the samples, play them through an aggregate device. Latency and cost need a spike. Alternative: an Audio Server Plug-In (HAL virtual device) installed to `/Library/Audio/Plug-Ins/HAL`, which is heavier and needs admin. Decide in the M10 spike.

### 6.12 Projects and ports

- Listening sockets: for each readable PID, `proc_pidinfo(PROC_PIDLISTFDS)`, then `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for socket fds; keep TCP sockets in `LISTEN` state; port from the local endpoint.
- Working directory: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `pvi_cdir`.
- Project root: walk up from cwd to the nearest folder containing `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, `pom.xml`, `deno.json`, or `.git`. Project name = folder name.
- Runtime: from executable name and, for node, the script argument (`proc_pidinfo` argv via `sysctl KERN_PROCARGS2`).
- Idle: CPU time delta ≈ 0 over 15 min → "idle N min"; up ≥ 24 h with total CPU time under 60 s → "barely used".
- Stop: `SIGTERM` to the process group, wait 5 s, `SIGKILL` if still alive, then re-scan and confirm the port is free.

### 6.13 Sampling loop

One `Sampler` actor, one timer. Interval 10 s idle (D-051; originally 5 s), 1 s while the main window or the menu bar window is visible. Each tick: enumerate PIDs, read per-process metrics, resolve apps (cached), compute deltas, publish one `Snapshot` value to a broadcast stream. UI subscribes to snapshots; History and Alerts subscribe to the same stream. Nothing else polls.

### 6.14 Menu bar

`MenuBarExtra` with `.menuBarExtraStyle(.window)` for icon and figure modes; the window is glass by default on 26+. Figure, graph and stacked modes render to a template image inside `MenuBarExtra`, which gives them custom, stable widths without a separate `NSStatusItem` (D-020, D-067). One `MenuBarContent` view serves both paths. Strain state swaps the symbol and tints the figure amber (10.2).

### 6.15 Export

`ImageRenderer` on a dedicated SwiftUI view at 1200 × 630 @2x. Colors from the design tokens (Section 10), not from the current window's appearance.

## 7. Data model (Core)

```swift
struct AppIdentity: Hashable { let id: String; let name: String; let bundleID: String?; let iconKey: String; let kind: Kind }  // kind: app, terminal, system, other
struct ProcessSample { let pid: Int32; let app: AppIdentity.ID; let cpuTime: Duration; let footprintBytes: UInt64; let diskRead: UInt64; let diskWrite: UInt64; let energyNJ: UInt64; let netIn: UInt64?; let netOut: UInt64?; let gpuPercent: Double? }
struct SystemSample { cpu: CPUStats; memory: MemoryStats; disk: DiskStats; network: NetworkStats; gpu: GPUStats?; battery: BatteryStats?; sensors: SensorStats? }
struct Snapshot { let at: Date; let interval: Duration; let system: SystemSample; let apps: [AppAggregate]; let processes: [ProcessSample] }
struct AppAggregate { let app: AppIdentity; let processCount: Int; let cpuPercent: Double; let memoryBytes: UInt64; let energyMW: Double?; let diskReadBPS: Double; let diskWriteBPS: Double; let netInBPS: Double?; let netOutBPS: Double?; let gpuPercent: Double? }
enum Metric: CaseIterable { case cpu, memory, energy, diskRead, diskWrite, netIn, netOut, gpu }
enum Range { case h12, h24, d7, d30 }
```

### 7.1 Protocols (one per data source, all in Core)

`ProcessSource`, `CPUSource`, `MemorySource`, `DiskSource`, `NetworkSource`, `GPUSource`, `BatterySource`, `SensorSource`, `ProjectSource`, `AudioSource`, `AppResolver`, `HistoryStore`, `AlertDeliverer`, `ProcessTerminator`. Each is `Sendable`, async, and has a `Simulated*` twin. A feature module's own sources (Docker, Storage, Startup, process details) keep their protocols in that module (D-087).

### 7.2 Units and formatting

One `Formatters` namespace in Core: bytes (SI, `kB/MB/GB`, one decimal above 10), rates (`kB/s`), percent (no decimals), power (`mW` under 1 W, `W` above), durations (`2h 46m`), temperature (°, unit from locale). Every number on screen goes through it; never hand-format.

### 7.3 Defined states

- **Strain** (menu bar warning): CPU ≥ 85% for 60 s, or memory pressure ≥ warning, or free disk < 5%, or thermal pressure ≥ heavy.
- **Memory status word:** Normal / Elevated / Critical from `kern.memorystatus_level` thresholds.
- **Activity state (projects):** working / idle / barely used (6.12).

## 8. Quality bars

- Idle cost under 0.25% of one core (D-266), and physical footprint under 35 MB if the window was never opened and under 75 MB once it has been opened and closed (D-268), measured, at every milestone.
- Installed size: the app bundle under 50 MB (`make size`; 25 MB, 8 MB zipped, at the time of D-058), and the history database under about 60 MB at the longest retention, a year (D-089).
- Cold launch to menu bar item under 500 ms; menu bar window opens under 100 ms with the last snapshot.
- Zero private-API code outside `PrivateAPIs`; every wrapper has a fallback and a test.
- Grouping totals equal Activity Monitor's within 5% on the same tick for the user's own processes.
- Every view renders from `Simulated` data in SwiftUI previews.
- Every screen passes a side-by-side with a native Apple app (System Settings, Activity Monitor, Passwords) in light and dark mode, with Reduce Transparency on and off, and at the smallest supported window size. If it looks like a third-party app, it isn't done.
- Live figures roll their changed digits into place (`FigureText`, D-053; originally `.contentTransition(.numericText())`); nothing on screen jumps or flickers on a sample tick.
- Notarized build from `make release` on a clean checkout.

## 9. Expansions — beyond the baseline (parked)

Decision: **no expansions until the baseline is real.** The decision comes after using Mactivity daily for a week or two, which lands around M6–M7. Until then the list below is a parking lot, not a plan. Add to it freely; don't build from it.

Effort: S = a day, M = a few days, L = a week or more.

| # | Idea | Effort | Notes |
|---|------|--------|-------|
| E1 | **Connections per app.** Which hosts each app is talking to right now (public socket enumeration, 6.5b). Network tab gets an expandable "Connections" row per app. | M | Public API, low risk |
| E2 | **"While you were away" digest.** A once-a-day notification (or at wake) summarizing the top CPU/memory/network apps since the window was last opened, and any alerts that fired. | S | Built entirely on the History store |
| E3 | **Compare ranges.** History strip gains "vs previous period": this week's top apps next to last week's, with deltas. | M | |
| E4 | **Startup audit.** What runs at login: login items, LaunchAgents, LaunchDaemons, the app that installed each, one-click disable where `SMAppService` allows. | M | Ties into "what did I leave running" |
| E5 | **Containers under Docker.** In Projects, expand the Docker row to show containers (name, image, CPU, memory) via the Docker socket, with stop/restart. | M | |
| E6 | **CLI + Shortcuts.** `mactivity top --memory --json` for scripts, and App Intents so Shortcuts and Siri can read figures and stop idle servers. | M | App Intents also feed Spotlight on 26+ |
| E7 | **Desktop widgets.** WidgetKit small/medium widgets for CPU, memory, and battery, fed from the last snapshot. Liquid Glass widgets on 26+. | S–M | |
| E8 | **Thermal history.** Temperature and fan history on the same 30-day store, with throttling events marked on the CPU chart. | S | |
| E9 | **Another Mac.** Watch a second Mac on the local network over Bonjour + TLS. Read-only, no cloud. | L | Only if the single-Mac app is done |
| E10 | **Storage map.** Scan a volume with `getattrlistbulk`, show a sunburst or treemap by folder and file type, with sizes that respect APFS clones and purgeable space. Reveal in Finder; Move to Trash only through `ConfirmedAction`. A "Developer" lens sums what's safe to rebuild: Xcode DerivedData, Archives, simulator runtimes, `node_modules`, Homebrew and pip caches, Docker images. | L | Needs Full Disk Access for a complete scan (else TCC asks per folder). Showing, not cleaning (spec 3): no automatic deletes. |
| E11 | **Per-app network, for real.** `NetworkStatistics.framework` via `PrivateAPIs` with the current fallback. Fills the one empty column in the app list (D-024). | M | Private API, brittle across releases |
| E12 | **Process inspector.** Select a process: command line, cwd, open files and sockets, parent chain, start time, CPU/memory history for that PID. | M | Public `proc_pidinfo`, read-only |
| E13 | **Energy Impact score.** Activity Monitor's single "energy impact" figure per app, next to mW, so the Battery tab answers "what's draining me" in one number. | S | Formula isn't public; approximate from CPU, GPU, wakeups, energy |
| E14 | **Battery health history.** Max capacity and cycles over months, charge-limit status, and "time on battery" per day, from the history store. | S | |
| E15 | **Per-app audio.** Mute, remembered levels, and a per-app output device, in the Volume tab and the menu bar window. Extends 5.7; experimental until consent is checked on screen (D-054). | M | |

Rule for expansions: each one is its own package target or a clearly bounded addition to an existing one, behind a feature flag in Settings until it's solid.

## 10. Design — Apple's current design language, done properly

This is the part that sets Mactivity apart. Mactivity looks like Apple shipped it in macOS 27: Liquid Glass, native components, light and dark as equals, generous where it can be and dense only where the data demands it.

### 10.1 Principles

1. **Native first.** If macOS has a component for it, use that component. Sidebar, toolbar, forms, lists, tables, pickers, menus, popovers: all system. We don't reinvent the sidebar to make it look cooler. The system's version already matches every other app on the user's Mac, and on 27 it gets the edge-to-edge sidebar and unified toolbar for free.
2. **Glass is for chrome, not content.** Liquid Glass belongs on the layer that floats above content: toolbars, the menu bar window, floating controls, the strain badge. Content (charts, lists, cards) sits on solid or grouped-background surfaces so it stays readable. Never put a chart on glass.
3. **Hierarchy through type and space, not through boxes.** Big figures are big. Labels are small and secondary. Cards are grouped-background rectangles with the system corner radius, not bordered panels.
4. **Both appearances, equally.** Light mode is not dark mode with inverted colors. Every screen is designed in both from the start, using semantic colors so the system does most of the work.
5. **Accessibility is a design constraint.** Reduce Transparency, Increase Contrast, Reduce Motion, and the 27 glass-opacity slider all have to produce a screen that still looks intentional. Test them every milestone.
6. **Motion means something.** Numbers tick: changed digits roll into place while the window is active (D-053). A row expands with a matched geometry effect. An alert badge bounces once. Nothing else moves.

### 10.2 Component map

| Surface | Build it with | Notes |
|---------|---------------|-------|
| Main window | `WindowGroup` scene with one value, so there is only ever one (D-270) → `NavigationSplitView` | Sidebar + detail. Unified toolbar. Standard title bar; don't hide it. |
| Sidebar | `List` with `.listStyle(.sidebar)`, sections, SF Symbols | Items: Overview, then CPU / Memory / Disk / Network / GPU / Battery under "Metrics", then Projects, Alerts, History under "More". Colored symbols on 27; tinted with the accent on 26. |
| Toolbar | `.toolbar { }` with `ToolbarItem`, `ToolbarSpacer` | Range picker (12 h / 24 h / 7 d / 30 d / 90 d / 1 y) as a segmented control, search, "Simulated data" only in debug. Glass grouping comes from the system. |
| Detail: headline card | `GroupBox` or a `RoundedRectangle` with `.fill(.background.secondary)` and the system radius | One big figure (`.font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()`), status word, sparkline. |
| Detail: secondary figures | `LabeledContent` in a `Grid` | Label secondary, value primary, tabular digits. |
| History strip | Swift Charts: binned bars (`RectangleMark`, at most 180, peak behind average), `.chartXSelection` for scrubbing (D-056) | Accent bars over a faint track. Threshold rule marks (`RuleMark`) for alert lines. Sparklines are bars too. |
| App list | `Table` on wide windows, `List` with `DisclosureGroup` rows on narrow | Alternating row backgrounds, icon at 20 pt, name, process count as secondary text, figure right-aligned with tabular digits. Expand shows processes. Context menu: Quit, Force Quit, Show in Finder. |
| Overview grid | `LazyVGrid` of headline cards, 2–3 columns adaptive | Memory-by-type and Memory-by-app as `SectorMark` donuts from Swift Charts. |
| Projects | `Table` grouped by project, header summary with a `.glassProminent` "Stop Idle…" button and a glass "Stop All…" (D-030) | Runtime shown as a small capsule tag. Idle state in secondary text, amber if "barely used". |
| Menu bar item | `MenuBarExtra` with `.menuBarExtraStyle(.window)` for every mode; figure, graph and stacked draw as images for stable custom widths (D-067) | The window gets glass from the system. Same card components as the main window, smaller. |
| Strain state | SF Symbol swap with `.symbolEffect(.bounce, value:)` once, then static; menu bar figure tinted amber | Never red. Red is for Force Quit only. |
| Alerts (notifications) | `UNUserNotificationCenter` with the app icon; body is the evidence | Clicking deep-links to the tab with the app row highlighted and pulsed once. |
| Confirmations | System `.confirmationDialog` / `.alert` | Destructive button uses the destructive role. |
| Settings | `Settings` scene, `TabView` with SF Symbol tabs, `Form` with `.formStyle(.grouped)` | Looks exactly like System Settings panes. |
| Onboarding | One sheet on first launch: what it does, the one network call, "Show in menu bar" | Glass background, one prominent button. Covers the 27 menu bar visibility change if it's real. |
| App icon | Icon Composer `.icon` asset, layered | Glyph over a gradient, glass handled by the system on 26/27. Design in Icon Composer, not Photoshop. |
| Share card | `ImageRenderer`, 1200 × 630, its own light and dark tokens | Same type and card language as the app so the post looks like the app. |

### 10.3 Tokens (`Sources/UI/Tokens.swift`)

Everything below is a named constant; no view uses a raw number or a raw color.

- **Accent:** one system-derived accent (`Color.accentColor`, so the user's system accent is respected by default) with an optional in-app override. Status: `Color.green` / `Color.yellow` / `Color.orange` / `Color.red`, semantic, used only for status words and the strain badge. Each metric has its own color (CPU blue, memory purple, disk orange, network teal, GPU pink, battery green), shared by its sidebar symbol, card symbol, sparkline and history bars (D-057); charts without a metric use the accent.
- **Type:** SF Pro throughout. Figures use `design: .rounded` and `.monospacedDigit()`. PIDs, paths, ports use `.monospaced`. Sizes: hero 44, headline 28, body 13, secondary 11 (system default scale; the tokens name them, they don't override Dynamic Type).
- **Spacing:** 4 / 8 / 12 / 16 / 24 / 32. Card padding 16. Grid gutter 12.
- **Radii:** cards use the system corner radius via `ConcentricRectangle` / the container's corner style where available on 27, else 12 pt. Capsules for tags.
- **Materials:** chrome uses `.glassEffect()` (26+) with the regular style; content surfaces use `.background.secondary` / `.background.tertiary`. No custom blurs.
- **Icon size:** 20 pt in rows, 32 pt in cards, 64 pt in share card.

### 10.4 What "beautiful" means here, so it's testable

- The Overview at 1100 × 720 fits without scrolling and every figure is readable at arm's length.
- Side by side with System Settings and Activity Monitor on the same desktop, the window looks like it belongs to the same OS release.
- A screenshot of the CPU tab in light mode looks like a marketing image without any editing.
- Nothing custom-drawn where a system component exists. If a reviewer asks "why did you draw that?" the answer is never "it looked cooler."

### 10.5 Reference material

Before M1, drop screenshots into `docs/design/` of: System Settings (Battery pane), Activity Monitor (CPU tab), Passwords, the Weather app's cards, and any third-party Liquid Glass app that gets it right. Claude Code reads that folder at the start of any UI task.

## 11. Milestones

M0–M10 are built and shipped. This section is kept as the original build order.

Each milestone ends with a green `make build && make test`, the idle performance number written down, and a light + dark screenshot of every screen touched, saved to `docs/screenshots/<milestone>/`.

| M | Name | Contents | Done when |
|---|------|----------|-----------|
| M0 | Walking skeleton | Repo scaffold, XcodeGen, Makefile, Core protocols, Simulated package, real CPU sampler, `Tokens.swift`, Icon Composer icon, `MenuBarExtra` with live CPU %, `NavigationSplitView` shell with sidebar, Overview showing the CPU headline card | `make run` shows a live CPU % in the menu bar and a native-looking window |
| M1 | Apps, not processes | Process enumeration, per-process metrics, app resolution with cache, `Snapshot` stream, CPU + Memory tabs fully built from the Section 4.3 skeleton with the 10.2 components, app rows expandable | CPU and Memory tabs match Activity Monitor within 5%, in both appearances |
| M2 | Memory of things | GRDB store, three tiers, rollups, retention, history strip on CPU and Memory tabs with all four ranges and scrubbing, top apps per range | Relaunch shows yesterday's history |
| M3 | The rest of the metrics | Disk, Network (system + spike per-app), GPU (system + spike per-app), Battery tabs; Overview grid complete with donuts | All eight tabs populated with real data |
| M4 | It tells you | Alert engine, four rules, cooldown/mute/quiet hours/frontmost exemption, notifications that deep-link; flip to Swift 6 language mode | A synthetic CPU hog triggers a notification within 10 min |
| M5 | Menu bar for real | Four display modes, metric picker, strain state, glass window with Overview + per-metric tabs; onboarding sheet | Menu bar window opens under 100 ms |
| M6 | Projects | Ports, cwd, project roots, runtime, idle detection, Stop / Stop All with confirmation and toast | Stopping a dev server frees its port, verified by re-scan |
| M7 | Sensors | Temperatures, fans, battery health/cycles/power, peripheral batteries; temperature as a menu bar metric | Numbers match `powermetrics` within noise |
| M8 | Ship-shape | Quit/Force Quit everywhere via `ConfirmedAction`, export share card + copy dashboard, launch at login, Settings, Sparkle, `make release` notarized | A notarized DMG installs and updates itself |
| M9 | Helper | Privileged read-only XPC daemon, "System" row becomes real, root processes quittable | Helper enabled → process count matches Activity Monitor |
| M10 | Volume per app | Process-tap spike, then the feature or a documented no | Slider changes one app's volume without affecting others |
| M11+ | Expansions | Whatever is picked from Section 9 after using the app, one milestone each | Per feature |

There is no separate "design pass": every milestone ships its screens finished to the Section 10 bar. Order can shift. What can't: M0 before anything, M1 before M2, M8 before anyone outside uses it.

## 12. Distribution and licensing

Decision: **free and open source, distributed outside the App Store.** The source is under the MIT license (`LICENSE`). There is no license key, no account, no trial and no paid tier.

Mactivity 1.0 to 1.9 were sold for a one-time payment with a license key. That ended in late 2026: the licensing code, the license screens and the store were removed, and every build since runs for everyone.

### 12.1 What a release needs

- Apple Developer Program membership for Developer ID signing and notarization (`docs/APPLE-DEVELOPER.md`).
- Sparkle EdDSA key pair; the public key ships in `Info.plist`, the private key never touches the repo.
- A static website with the download, the changelog and the privacy list.

The privacy list in 5.10 stays true: the update check, and nothing else unless the user turns it on.

## 13. Open questions

None are open. How each was answered:

1. Price: free and open source (Section 12).
2. Accent: charts use one color per metric, not the system accent (D-057).
3. Frontmost-app alert exemption: a setting, on by default (5.4).
4. macOS 27 doesn't hide third-party menu bar items by default (checked against the SDK in session one).
