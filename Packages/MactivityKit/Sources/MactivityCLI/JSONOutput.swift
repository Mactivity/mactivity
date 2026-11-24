import Core
import Foundation
import Readouts

/// `--json` output. The schema is versioned and documented in `mactivity help json`; add fields
/// freely, but renaming or removing one bumps `schemaVersion`.
///
/// Conventions: raw numbers (bytes, bytes per second, milliwatts, percent 0–100 of the whole
/// machine), rounded to two decimals; ISO 8601 dates in this Mac's time zone, with its offset (D-220); keys sorted; unavailable figures are
/// `null`, never missing.
enum JSONOutput {
    static let schemaVersion = 1

    /// Compact for the MCP server, whose reader pays per token (D-152).
    static func encode(_ value: some Encodable, pretty: Bool = true, timeZone: TimeZone = .autoupdatingCurrent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.date(date, timeZone: timeZone))
        }
        guard let text = try String(bytes: encoder.encode(value), encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return text
    }

    /// "2026-09-25T15:30:00+05:30": the Mac's clock time, and its offset so it's still one instant.
    /// A reader quoting the time to someone (an agent over MCP) reads the time they saw.
    static func date(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
    }

    static func round(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return (value * 100).rounded() / 100
    }

    static func round(_ value: Double?) -> Double? {
        value.map(round)
    }

    static func seconds(_ duration: Duration) -> Double {
        round(duration.seconds)
    }
}

/// Encodes nil as `null` instead of leaving the key out, so every documented key is always there.
@propertyWrapper
struct NullEncoded<Value: Encodable>: Encodable {
    /// A `let`, so the synthesized `init(wrappedValue:)` has no default and the enclosing
    /// structs' memberwise inits take plain optionals.
    let wrappedValue: Value?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - top

struct TopJSON: Encodable {
    struct App: Encodable {
        let id: String
        let name: String
        /// app | terminal | system | other
        let kind: String
        @NullEncoded var bundleID: String?
        let processCount: Int
        let cpuPercent: Double
        let memoryBytes: UInt64
        @NullEncoded var energyMilliwatts: Double?
        let diskReadBytesPerSecond: Double
        let diskWriteBytesPerSecond: Double
        @NullEncoded var networkInBytesPerSecond: Double?
        @NullEncoded var networkOutBytesPerSecond: Double?
        @NullEncoded var gpuPercent: Double?
    }

    let schemaVersion = JSONOutput.schemaVersion
    let command = "top"
    let sampledAt: Date
    let intervalSeconds: Double
    let sortedBy: String
    let apps: [App]

    init(_ snapshot: Snapshot, options: Command.TopOptions) {
        sampledAt = snapshot.at
        intervalSeconds = JSONOutput.seconds(snapshot.interval)
        sortedBy = options.ranking.rawValue
        apps = options.ranking.rank(snapshot.apps, limit: options.limit).map { app in
            App(
                id: app.app.id,
                name: app.app.name,
                kind: app.app.kind.rawValue,
                bundleID: app.app.bundleID,
                processCount: app.processCount,
                cpuPercent: JSONOutput.round(app.cpuPercent),
                memoryBytes: app.memoryBytes,
                energyMilliwatts: JSONOutput.round(app.energyMW),
                diskReadBytesPerSecond: JSONOutput.round(app.diskReadBPS),
                diskWriteBytesPerSecond: JSONOutput.round(app.diskWriteBPS),
                networkInBytesPerSecond: JSONOutput.round(app.netInBPS),
                networkOutBytesPerSecond: JSONOutput.round(app.netOutBPS),
                gpuPercent: JSONOutput.round(app.gpuPercent)
            )
        }
    }
}

// MARK: - system

struct SystemJSON: Encodable {
    struct Cluster: Encodable {
        let name: String
        let level: Int
        let coreCount: Int
        let percent: Double
    }

    struct CPU: Encodable {
        let totalPercent: Double
        let userPercent: Double
        let systemPercent: Double
        let coreCount: Int
        let clusters: [Cluster]
        /// 1, 5, and 15 minutes.
        let loadAverage: [Double]
    }

    struct Memory: Encodable {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let appBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let cachedFilesBytes: UInt64
        let swapUsedBytes: UInt64
        /// normal | warning | critical
        let pressure: String
    }

    struct Volume: Encodable {
        let name: String
        let totalBytes: UInt64
        let freeBytes: UInt64
    }

    struct Disk: Encodable {
        let readBytesPerSecond: Double
        let writeBytesPerSecond: Double
        /// Boot volume first.
        let volumes: [Volume]
    }

    struct Network: Encodable {
        let inBytesPerSecond: Double
        let outBytesPerSecond: Double
        @NullEncoded var interface: String?
    }

    struct GPU: Encodable {
        let name: String
        let utilizationPercent: Double
        @NullEncoded var memoryInUseBytes: UInt64?
    }

    struct Battery: Encodable {
        let percent: Double
        let isCharging: Bool
        /// battery | ac
        let powerSource: String
        /// To empty on battery, to full on AC; null while macOS is still estimating.
        @NullEncoded var timeRemainingSeconds: Double?
        @NullEncoded var cycleCount: Int?
        @NullEncoded var maxCapacityPercent: Double?
        @NullEncoded var powerDrawWatts: Double?
    }

    let schemaVersion = JSONOutput.schemaVersion
    let command = "system"
    let sampledAt: Date
    let intervalSeconds: Double
    let cpu: CPU
    let memory: Memory
    let disk: Disk
    let network: Network
    @NullEncoded var gpu: GPU?
    @NullEncoded var battery: Battery?
    /// nominal | fair | serious | critical
    let thermal: String
    let uptimeSeconds: Double

    init(_ snapshot: Snapshot) {
        let system = snapshot.system
        sampledAt = snapshot.at
        intervalSeconds = JSONOutput.seconds(snapshot.interval)
        cpu = CPU(
            totalPercent: JSONOutput.round(system.cpu.totalPercent),
            userPercent: JSONOutput.round(system.cpu.userPercent),
            systemPercent: JSONOutput.round(system.cpu.systemPercent),
            coreCount: system.cpu.perCorePercent.count,
            clusters: system.cpu.clusters.sorted { $0.level < $1.level }.map {
                Cluster(name: $0.name, level: $0.level, coreCount: $0.coreIndexes.count, percent: JSONOutput.round($0.percent))
            },
            loadAverage: [system.cpu.loadAverage.one, system.cpu.loadAverage.five, system.cpu.loadAverage.fifteen].map(JSONOutput.round)
        )
        let memory = system.memory
        self.memory = Memory(
            totalBytes: memory.totalBytes, usedBytes: memory.usedBytes, appBytes: memory.appBytes, wiredBytes: memory.wiredBytes,
            compressedBytes: memory.compressedBytes, cachedFilesBytes: memory.cachedFilesBytes, swapUsedBytes: memory.swapUsedBytes,
            pressure: memory.pressure.rawValue
        )
        disk = Disk(
            readBytesPerSecond: JSONOutput.round(system.disk.readBPS),
            writeBytesPerSecond: JSONOutput.round(system.disk.writeBPS),
            volumes: system.disk.volumes.map { Volume(name: $0.name, totalBytes: $0.totalBytes, freeBytes: $0.freeBytes) }
        )
        network = Network(
            inBytesPerSecond: JSONOutput.round(system.network.inBPS),
            outBytesPerSecond: JSONOutput.round(system.network.outBPS),
            interface: system.network.primaryInterface
        )
        _gpu = NullEncoded(wrappedValue: system.gpu.map {
            GPU(name: $0.name, utilizationPercent: JSONOutput.round($0.utilizationPercent), memoryInUseBytes: $0.memoryInUseBytes)
        })
        _battery = NullEncoded(wrappedValue: system.battery.map {
            Battery(
                percent: JSONOutput.round($0.percent),
                isCharging: $0.isCharging,
                powerSource: $0.source.rawValue,
                timeRemainingSeconds: $0.timeRemaining.map(JSONOutput.seconds),
                cycleCount: $0.cycleCount,
                maxCapacityPercent: JSONOutput.round($0.maxCapacityPercent),
                powerDrawWatts: JSONOutput.round($0.powerDrawWatts)
            )
        })
        thermal = system.thermal.rawValue
        uptimeSeconds = JSONOutput.seconds(system.uptime)
    }
}

// MARK: - projects

struct ProjectsJSON: Encodable {
    struct Server: Encodable {
        let pid: Int32
        let name: String
        let command: String
        let runtime: String
        let ports: [UInt16]
        let memoryBytes: UInt64
        let startedAt: Date
        let cpuSeconds: Double
        /// working | idle | barelyUsed
        let activity: String
        @NullEncoded var idleMinutes: Int?
    }

    struct Project: Encodable {
        let name: String
        let path: String
        let runtime: String
        let ports: [UInt16]
        let memoryBytes: UInt64
        let activity: String
        @NullEncoded var idleMinutes: Int?
        let servers: [Server]
    }

    let schemaVersion = JSONOutput.schemaVersion
    let command = "projects"
    let scannedAt: Date
    /// How long the CLI watched CPU use. Idle needs 15 minutes of watching, which only the
    /// running app does, so the CLI reports `working` or `barelyUsed`.
    let activityWindowSeconds: Double
    let projects: [Project]

    init(_ projects: [Core.Project], scannedAt: Date, activityWindow: Duration) {
        self.scannedAt = scannedAt
        activityWindowSeconds = JSONOutput.seconds(activityWindow)
        self.projects = projects.map { project in
            Project(
                name: project.name,
                path: project.rootPath,
                runtime: project.runtime.rawValue,
                ports: project.ports,
                memoryBytes: project.memoryBytes,
                activity: Self.activity(project.activity),
                idleMinutes: Self.idleMinutes(project.activity),
                servers: project.servers.map { server in
                    Server(
                        pid: server.pid,
                        name: server.name,
                        command: server.command,
                        runtime: server.runtime.rawValue,
                        ports: server.ports,
                        memoryBytes: server.memoryBytes,
                        startedAt: server.startedAt,
                        cpuSeconds: JSONOutput.seconds(server.cpuTime),
                        activity: Self.activity(server.activity),
                        idleMinutes: Self.idleMinutes(server.activity)
                    )
                }
            )
        }
    }

    static func activity(_ activity: ProjectActivity) -> String {
        switch activity {
        case .working: "working"
        case .idle: "idle"
        case .barelyUsed: "barelyUsed"
        }
    }

    static func idleMinutes(_ activity: ProjectActivity) -> Int? {
        if case let .idle(minutes) = activity {
            return minutes
        }
        return nil
    }
}
