import Foundation

// Local databases (D-277): PostgreSQL, MySQL, Redis and MongoDB running on this Mac, found by
// their process names, with their memory, their data on disk, and the ones with no sign of use in
// weeks. Never connects to one and never opens a file in its data folder: only names, sizes and
// modified times.

public enum DatabaseEngine: String, CaseIterable, Hashable, Sendable {
    case postgres, mysql, mariadb, redis, mongodb

    /// Product names, verbatim.
    public var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .redis: "Redis"
        case .mongodb: "MongoDB"
        }
    }

    /// The server process's name; nil for anything else. Not `psql`, `mysql` or `redis-cli`.
    public init?(processName: String) {
        switch processName {
        case "postgres", "postmaster": self = .postgres
        case "mysqld": self = .mysql
        case "mariadbd": self = .mariadb
        case "redis-server": self = .redis
        case "mongod": self = .mongodb
        default: return nil
        }
    }
}

/// One database server: its main process and the ones it started.
public struct LocalDatabase: Hashable, Sendable, Identifiable {
    /// How its data folder was found.
    public enum DataSource: String, Hashable, Sendable {
        /// Named in its arguments, or in the config file they name.
        case arguments
        /// Its working folder: PostgreSQL, MySQL and Redis all move into theirs.
        case workingDirectory
        /// Homebrew's usual place, there and looking like one.
        case usualPlace
    }

    public let pid: Int32
    public let engine: DatabaseEngine
    public let pids: [Int32]
    public let memoryBytes: UInt64
    public let startedAt: Date?
    public let ports: [UInt16]
    /// Nil when it couldn't be found, or didn't look like this engine's.
    public let dataDirectory: String?
    public let dataSource: DataSource?
    /// Connections open right now, over TCP or a Unix socket; nil if its sockets can't be read.
    public let connections: Int?
    /// Its figures could be read: a database running as another user's needs the helper.
    public let isReadable: Bool
    /// The process's name in History, which records it as "other:<name>".
    public let processName: String

    public var id: Int32 {
        pid
    }

    public init(
        pid: Int32, engine: DatabaseEngine, pids: [Int32], memoryBytes: UInt64, startedAt: Date?, ports: [UInt16], dataDirectory: String?,
        dataSource: DataSource?, connections: Int?, isReadable: Bool, processName: String
    ) {
        self.pid = pid
        self.engine = engine
        self.pids = pids
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
        self.ports = ports
        self.dataDirectory = dataDirectory
        self.dataSource = dataSource
        self.connections = connections
        self.isReadable = isReadable
        self.processName = processName
    }
}

/// What a walk of a data folder found: names, sizes and modified times, nothing from inside a file.
public struct DatabaseDiskUse: Hashable, Sendable {
    public let bytes: UInt64
    /// The newest write among the files a database only changes when it's used.
    public let lastWrite: Date?

    public init(bytes: UInt64, lastWrite: Date?) {
        self.bytes = bytes
        self.lastWrite = lastWrite
    }
}

/// Live reads the process table and the data folders; Simulated has a fixed set.
public protocol LocalDatabaseSource: Sendable {
    /// The databases running now. Quick: no folder is walked.
    func databases() async -> [LocalDatabase]
    /// Walks its data folder. Only while the view shows, and the view keeps the answer.
    func diskUse(of database: LocalDatabase) async -> DatabaseDiskUse?
}

/// Pure rules, with the file system and process table passed in.
public enum LocalDatabaseRules {
    /// "Nothing has used it in weeks": two of them, as Homebrew's quiet services.
    public static let quietAfter: TimeInterval = 14 * 86400

    // MARK: Where the data is

    /// What's left of the data folder's value after its option, in either spelling.
    private static func option(_ names: [String], in arguments: [String]) -> String? {
        for (index, word) in arguments.enumerated() {
            for name in names {
                if word == name, index + 1 < arguments.count {
                    return arguments[index + 1]
                }
                if word.hasPrefix(name + "=") {
                    return String(word.dropFirst(name.count + 1))
                }
                // Postgres's `-D/path`.
                if name == "-D", word.hasPrefix("-D"), word.count > 2 {
                    return String(word.dropFirst(2))
                }
            }
        }
        return nil
    }

    /// A MongoDB config file's `dbPath:` line, or an old-style `dbpath=`. Its config, not its data.
    public static func mongoPath(config: String) -> String? {
        for line in config.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), text.lowercased().hasPrefix("dbpath") else {
                continue
            }
            let value = text.dropFirst("dbpath".count).drop { $0 == " " || $0 == ":" || $0 == "=" }
            let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return clean.isEmpty ? nil : clean
        }
        return nil
    }

    /// Homebrew's usual folders, for a database whose arguments and working folder don't say.
    private static func usualPlaces(_ engine: DatabaseEngine, prefixes: [String]) -> [String] {
        let folders = switch engine {
        case .postgres: ["var/postgresql@17", "var/postgresql@16", "var/postgresql@15", "var/postgresql@14", "var/postgres"]
        case .mysql, .mariadb: ["var/mysql"]
        case .redis: ["var/db/redis"]
        case .mongodb: ["var/mongodb"]
        }
        return prefixes.flatMap { prefix in folders.map { prefix + "/" + $0 } }
    }

    /// What a folder has to hold to be this engine's. The names only.
    private static func looksRight(_ engine: DatabaseEngine, _ path: String, exists: (String) -> Bool) -> Bool {
        switch engine {
        case .postgres: exists(path + "/PG_VERSION")
        case .mysql, .mariadb: exists(path + "/ibdata1") || exists(path + "/mysql") || exists(path + "/auto.cnf")
        case .mongodb: exists(path + "/WiredTiger") || exists(path + "/storage.bson")
        // Redis keeps its files in any folder; only those are ever sized (`dataFiles`).
        case .redis: true
        }
    }

    /// The data folder, and how it was found; nil rather than a guess: its size would be a wrong
    /// figure. Never the home folder or `/`, which a Redis started by hand can be sitting in.
    public static func dataDirectory(
        engine: DatabaseEngine,
        arguments: [String],
        workingDirectory: String?,
        home: String,
        prefixes: [String] = ["/opt/homebrew", "/usr/local"],
        readFile: (String) -> String?,
        exists: (String) -> Bool
    ) -> (path: String, source: LocalDatabase.DataSource)? {
        let words = Array(arguments.dropFirst())
        var named: String?
        switch engine {
        case .postgres: named = option(["-D", "--data-directory"], in: words)
        case .mysql, .mariadb: named = option(["--datadir"], in: words)
        case .redis: named = option(["--dir"], in: words)
        case .mongodb:
            named = option(["--dbpath"], in: words)
            if named == nil, let config = option(["--config", "-f"], in: words) {
                named = readFile(absolute(config, from: workingDirectory)).flatMap(mongoPath)
            }
        }
        func allowed(_ path: String) -> Bool {
            path != "/" && path != home && !path.isEmpty && looksRight(engine, path, exists: exists)
        }
        if let named {
            let path = normalized(absolute(named, from: workingDirectory))
            return allowed(path) ? (path, .arguments) : nil
        }
        // MongoDB doesn't move into its data folder, so its working folder says nothing.
        if engine != .mongodb, let workingDirectory {
            let path = normalized(workingDirectory)
            if allowed(path) {
                return (path, .workingDirectory)
            }
        }
        let places = usualPlaces(engine, prefixes: prefixes).filter { exists($0) && allowed($0) }
        // More than one, and any could be this one's: don't pick.
        return places.count == 1 ? places.first.map { ($0, .usualPlace) } : nil
    }

    private static func absolute(_ path: String, from directory: String?) -> String {
        path.hasPrefix("/") ? path : (directory ?? "") + "/" + path
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Redis shares its folder with whatever else is there, so only its own files count; nil for
    /// the others, whose whole folder is theirs. `arguments`' `--dbfilename` renames the snapshot.
    public static func dataFiles(engine: DatabaseEngine, arguments: [String]) -> [String]? {
        guard engine == .redis else {
            return nil
        }
        // Only ever a name in that folder: nothing an argument says can lead the walk out of it.
        func name(_ option: String, default fallback: String) -> String {
            let given = Self.option([option], in: arguments).map { ($0 as NSString).lastPathComponent } ?? fallback
            return given == ".." || given == "." || given == "/" ? fallback : given
        }
        return [
            name("--dbfilename", default: "dump.rdb"), name("--appendfilename", default: "appendonly.aof"),
            name("--appenddirname", default: "appendonlydir"),
        ]
    }

    // MARK: What counts as use

    /// A file the database rewrites on its own, used or not, relative to its data folder. Left
    /// out of "last write". Not from a running server: none is installed where this was written,
    /// so the lists come from each engine's documented layout (D-277).
    public static func isBackgroundFile(_ engine: DatabaseEngine, _ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let top = path.split(separator: "/").first.map(String.init) ?? path
        switch engine {
        case .postgres:
            // Started, stopped, statistics, logs, and temporary files.
            return ["postmaster.pid", "postmaster.opts", "pg_stat", "pg_stat_tmp", "log", "pg_log", "logfile"].contains(top)
                || path.hasPrefix("base/pgsql_tmp") || name.hasSuffix(".log")
        case .mysql, .mariadb:
            return top == "#innodb_temp" || name == "ib_buffer_pool" || name == "auto.cnf" || name == "ibtmp1"
                || name == "aria_log_control" || [".pid", ".err", ".log", ".sock"].contains { name.hasSuffix($0) }
        case .redis:
            return false
        case .mongodb:
            // Writes these every minute while it runs, whether anyone's connected or not.
            return top == "diagnostic.data" || top == "journal" || name == "mongod.lock" || name == "WiredTiger.lock"
                || name == "WiredTiger.turtle" || name == "WiredTiger.wt" || name == "WiredTigerHS.wt" || name == "sizeStorer.wt"
                || name == "_mdb_catalog.wt" || name == "storage.bson" || name.hasSuffix(".log")
        }
    }

    /// Whether anything has used it.
    public enum Activity: Hashable, Sendable {
        case inUseNow
        /// A sign of use, the newer of a write to its data and a busy hour in History.
        case lastUsed(Date)
        /// Nothing for at least `quietAfter`. `since` is the newest sign, if it left one at all.
        case quiet(since: Date?)
        /// Too little to go on: no data folder, no figures, or under two weeks of History.
        case unknown
    }

    /// Says "quiet" only with both kinds of evidence, each covering the two weeks: no write to
    /// its data, which misses reads, and no busy hour, which misses light use. So a database only
    /// ever read, gently, can read as quiet; one that's merely idle after use can't read as used.
    public static func activity(
        connections: Int?, isReadable: Bool, lastWrite: Date?, dataKnown: Bool, lastBusy: Date?, historySince: Date?, now: Date
    ) -> Activity {
        if let connections, connections > 0 {
            return .inUseNow
        }
        let newest = [lastWrite, lastBusy].compactMap(\.self).max()
        let recent = newest.map { now.timeIntervalSince($0) < quietAfter } ?? false
        if recent, let newest {
            return .lastUsed(newest)
        }
        let enoughHistory = historySince.map { now.timeIntervalSince($0) >= quietAfter } ?? false
        guard isReadable, connections != nil, dataKnown, enoughHistory else {
            return newest.map(Activity.lastUsed) ?? .unknown
        }
        return .quiet(since: newest)
    }

    /// The newest hour at 1% of a core or more, from the process's History series.
    public static func lastBusy(_ points: [SeriesPoint]) -> Date? {
        points.last { $0.average >= 1 }?.at
    }

    /// The most memory first.
    public static func sorted(_ databases: [LocalDatabase]) -> [LocalDatabase] {
        databases.sorted { ($0.memoryBytes, $1.pid) > ($1.memoryBytes, $0.pid) }
    }

    /// The main processes: a server not started by another of the same engine. PostgreSQL's
    /// backends are all named `postgres` and are the postmaster's children.
    public static func mainProcesses(
        _ table: [(pid: Int32, parentPID: Int32, engine: DatabaseEngine)]
    ) -> [(pid: Int32, members: [Int32])] {
        let engines = Dictionary(table.map { ($0.pid, $0.engine) }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(table.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        func root(_ pid: Int32) -> Int32 {
            var current = pid
            var hops = 0
            while let parent = parents[current], engines[parent] == engines[pid], hops < 8 {
                current = parent
                hops += 1
            }
            return current
        }
        return Dictionary(grouping: table.map(\.pid), by: root)
            .map { (pid: $0.key, members: $0.value.sorted()) }
            .sorted { $0.pid < $1.pid }
    }
}
