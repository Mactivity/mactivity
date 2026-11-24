import Foundation

/// `--help` text. The JSON schema lives here too, so `mactivity help json` is the reference.
enum Help {
    static let overview = """
    mactivity: what your Mac is doing, grouped by app. Read-only.

    USAGE
      mactivity top [--cpu | --memory | --energy | --disk | --network] [--limit N] [--json]
      mactivity system [--json]
      mactivity projects [--json]
      mactivity agents [--days N] [--json]
      mactivity day [today | yesterday | YYYY-MM-DD] [--json]
      mactivity unusual [--json]
      mactivity builds [--days N] [--json]
      mactivity mcp
      mactivity help [top | system | projects | agents | day | unusual | builds | mcp | json]
      mactivity --version

    COMMANDS
      top        Apps sorted by a metric (CPU by default), processes summed per app.
      system     CPU, memory, disk, network, GPU, battery, and thermal state.
      projects   Dev servers with a listening port, grouped by project folder.
      agents     Coding agents' time per project over the last days, from history.
      day        A day as a timeline: wakes, slowdowns, charging, alerts, agents.
      unusual    Apps doing far more today than they usually do on this Mac.
      builds     How long each project's builds take, and whether they got slower.
      mcp        A Model Context Protocol server for coding agents (see `help mcp`).

    top, system and projects sample twice, about a second apart, so rates cover that
    second. agents, day, unusual and builds read the history Mactivity keeps, without changing it.
    Nothing is stopped or changed: to stop a server or quit an app, use Mactivity's
    Projects tab or app list, which ask first.

    EXIT STATUS
      0   success
      1   sampling or scanning failed, or output couldn't be written
      64  bad command line (see the message on stderr)
    """

    static let top = """
    mactivity top [--cpu | --memory | --energy | --disk | --network] [--limit N] [--json]

    Apps sorted by one metric, highest first. The macOS row holds system daemons and
    whatever couldn't be read without the helper.

      --cpu        percent of the whole machine (default)
      --memory     footprint, as Activity Monitor's Memory column
      --energy     power, milliwatts
      --disk       read + write, bytes per second
      --network    in + out, bytes per second, for your own apps. macOS doesn't report
                   system daemons' or other users' sockets, so the macOS row counts only
                   yours, and Safari's page loads count in the system total only
      -n, --limit N   how many apps (1–500, default 15)
      --json       machine-readable output (see `mactivity help json`)
    """

    static let mcp = """
    mactivity mcp

    A Model Context Protocol server on stdin and stdout, for Claude Code, Codex, Cursor
    and other agents. Its tools, all read-only:

      system        the whole Mac now (as `mactivity system --json`)
      top_apps      busiest apps, by cpu, memory, energy, disk or network
      why_slow      what's slowing the Mac down right now, worst first
      dev_servers   listening dev servers by project (as `mactivity projects --json`)
      agents        running AI agent sessions and what each one uses
      agent_history agents' time, processor and memory per project, by day
      day           a day as a timeline, today unless a date is given
      unusual_today apps doing far more today than their usual day on this Mac
      build_history each project's build times, and whether they got slower

    Add it to Claude Code:
      claude mcp add mactivity -- mactivity mcp

    Or to any client's JSON config:
      "mactivity": { "command": "/usr/local/bin/mactivity", "args": ["mcp"] }

    Nothing is stopped or changed, and Mactivity sends nothing anywhere. The agent sees
    the answers, so what it does with them is up to the agent you connect.
    """

    static let system = """
    mactivity system [--json]

    System-wide CPU (with per-cluster load and load average), memory, disks, network,
    GPU, battery, thermal pressure, and uptime.
    """

    static let agents = """
    mactivity agents [--days N] [--json]

    Coding agents (Claude Code, Codex, Gemini CLI, Aider and others) over the last N days
    (1–365, default 7), from the history Mactivity records while it runs: each agent's
    time per project, its average processor share and peak memory, and agent time by day.
    """

    static let day = """
    mactivity day [today | yesterday | YYYY-MM-DD] [--json]

    One day from Mactivity's history, in order: when the Mac woke and slept, busy
    stretches and slowdowns with the apps behind them, unplugging and charging, big
    downloads, alerts, crashes and agent sessions. Today unless a day is given.
    """

    static let unusual = """
    mactivity unusual [--json]

    Apps doing far more today than they usually do on this Mac: 2.5 times their usual
    processor, memory or power or more, or busy when they're usually idle. "Usual" is each
    app's median day over the last two weeks of Mactivity's history; with under five days
    of history, it's still learning and lists nothing.

    With --json, "today" and "usual" are percent of the whole Mac for cpu, bytes for
    memory and milliwatts for energy; "timesUsual" is null for an app usually idle.
    """

    static let builds = """
    mactivity builds [--days N] [--json]

    Builds over the last N days (1–365, default 7), timed from the compiler processes
    Mactivity sees while it runs (swift-frontend, xcodebuild, rustc, Go's compile, clang
    and others), by the project folder they run in. For each project: how many builds,
    the last one, and its median build this week beside the three weeks before.

    Builds are timed to within a second or two while a Mactivity window is open, and to
    about 10 seconds otherwise; builds shorter than that may not be seen. With --json,
    averageCPUPercent and peakMemoryBytes are what the samples caught: compiler processes
    that start and finish between two samples aren't in them, so read them as lower bounds.
    """

    static let projects = """
    mactivity projects [--json]

    Your processes that hold a listening TCP port, outside app bundles, grouped by the
    project folder they run in.

    Idle detection needs 15 minutes of watching, which only the running Mactivity app
    does. The CLI watches for one second, so it reports "Working" or "Barely used"
    (up a day with under a minute of CPU). The app's Projects tab shows idle times.
    """

    static let json = """
    JSON OUTPUT (schemaVersion 1)

    Every document has "schemaVersion" and "command". Keys are sorted; dates are ISO 8601
    in this Mac's time zone, with its offset (2026-09-25T15:30:00+05:30); figures are raw
    numbers rounded to two decimals; an unavailable figure is null,
    never a missing key. New keys may appear; renaming or removing one bumps schemaVersion.

    top
      { schemaVersion, command: "top", sampledAt, intervalSeconds,
        sortedBy: "cpu" | "memory" | "energy" | "disk" | "network",
        apps: [ { id, name, kind: "app" | "terminal" | "system" | "other", bundleID|null,
                  processCount, cpuPercent, memoryBytes, energyMilliwatts|null,
                  diskReadBytesPerSecond, diskWriteBytesPerSecond,
                  networkInBytesPerSecond|null, networkOutBytesPerSecond|null,
                  gpuPercent|null } ] }

    system
      { schemaVersion, command: "system", sampledAt, intervalSeconds,
        cpu: { totalPercent, userPercent, systemPercent, coreCount,
               clusters: [ { name, level, coreCount, percent } ], loadAverage: [1m, 5m, 15m] },
        memory: { totalBytes, usedBytes, appBytes, wiredBytes, compressedBytes,
                  cachedFilesBytes, swapUsedBytes, pressure: "normal" | "warning" | "critical" },
        disk: { readBytesPerSecond, writeBytesPerSecond,
                volumes: [ { name, totalBytes, freeBytes } ] },
        network: { inBytesPerSecond, outBytesPerSecond, interface|null },
        gpu: { name, utilizationPercent, memoryInUseBytes|null } | null,
        battery: { percent, isCharging, powerSource: "battery" | "ac", timeRemainingSeconds|null,
                   cycleCount|null, maxCapacityPercent|null, powerDrawWatts|null } | null,
        thermal: "nominal" | "fair" | "serious" | "critical", uptimeSeconds }

    projects
      { schemaVersion, command: "projects", scannedAt, activityWindowSeconds,
        projects: [ { name, path, runtime, ports, memoryBytes,
                      activity: "working" | "idle" | "barelyUsed", idleMinutes|null,
                      servers: [ { pid, name, command, runtime, ports, memoryBytes, startedAt,
                                   cpuSeconds, activity, idleMinutes|null } ] } ] }

    Percentages are 0–100 of the whole machine. Memory is bytes; rates are bytes per second.
    """

    /// Nil for an unknown topic.
    static func text(for topic: String?) -> String? {
        switch topic {
        case nil: overview
        case "top": top
        case "system": system
        case "projects": projects
        case "agents": agents
        case "day": day
        case "unusual": unusual
        case "builds": builds
        case "mcp": mcp
        case "json": json
        default: nil
        }
    }
}
