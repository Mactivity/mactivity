@testable import Core
import Foundation
import Testing

/// Local databases (D-277). Fixture-only: no database is installed where these were written, so
/// the arguments below are each server's documented forms, and Homebrew's formulas'.
struct LocalDatabasesTests {
    private let home = "/Users/demo"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func location(
        _ engine: DatabaseEngine, _ arguments: [String], cwd: String? = nil, files: Set<String> = [], config: [String: String] = [:]
    ) -> (path: String, source: LocalDatabase.DataSource)? {
        LocalDatabaseRules.dataDirectory(
            engine: engine, arguments: arguments, workingDirectory: cwd, home: home, readFile: { config[$0] },
            exists: { files.contains($0) }
        )
    }

    @Test("The server's process name, and not its clients'")
    func names() {
        #expect(DatabaseEngine(processName: "postgres") == .postgres)
        #expect(DatabaseEngine(processName: "postmaster") == .postgres)
        #expect(DatabaseEngine(processName: "mysqld") == .mysql)
        #expect(DatabaseEngine(processName: "mariadbd") == .mariadb)
        #expect(DatabaseEngine(processName: "redis-server") == .redis)
        #expect(DatabaseEngine(processName: "mongod") == .mongodb)
        for client in ["psql", "mysql", "mysqld_safe", "redis-cli", "mongo", "mongosh", "pg_dump", "postgres-exporter", ""] {
            #expect(DatabaseEngine(processName: client) == nil)
        }
    }

    @Test("PostgreSQL: -D in each spelling, checked for PG_VERSION")
    func postgresArguments() {
        let data = "/opt/homebrew/var/postgresql@16"
        let files: Set<String> = [data + "/PG_VERSION"]
        let brew = ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", data]
        #expect(location(.postgres, brew, files: files)?.path == data)
        #expect(location(.postgres, brew, files: files)?.source == .arguments)
        #expect(location(.postgres, ["postgres", "-D" + data], files: files)?.path == data)
        #expect(location(.postgres, ["postgres", "--data-directory=" + data], files: files)?.path == data)
        // A path that isn't a data folder isn't sized.
        #expect(location(.postgres, brew) == nil)
    }

    @Test("PostgreSQL moves into its data folder, so that's the fallback")
    func postgresWorkingFolder() throws {
        let data = home + "/Library/Application Support/Postgres/var-16"
        let found = try #require(location(.postgres, ["postgres"], cwd: data, files: [data + "/PG_VERSION"]))
        #expect(found.path == data && found.source == .workingDirectory)
    }

    @Test("A relative -D is from its working folder")
    func relative() {
        let files: Set = ["/srv/pg/data/PG_VERSION"]
        #expect(location(.postgres, ["postgres", "-D", "data"], cwd: "/srv/pg", files: files)?.path == "/srv/pg/data")
        #expect(location(
            .postgres,
            ["postgres", "-D", "../pg/data"],
            cwd: "/srv/x",
            files: ["/srv/x/../pg/data/PG_VERSION", "/srv/pg/data/PG_VERSION"]
        )?
            .path != nil)
    }

    @Test("MySQL and MariaDB: --datadir, either way, and what marks the folder")
    func mysql() {
        let data = "/opt/homebrew/var/mysql"
        #expect(location(.mysql, ["mysqld", "--basedir=/x", "--datadir=" + data, "--plugin-dir=/y"], files: [data + "/ibdata1"])?
            .path == data)
        #expect(location(.mysql, ["mysqld", "--datadir", data], files: [data + "/mysql"])?.path == data)
        #expect(location(.mariadb, ["mariadbd", "--datadir=" + data], files: [data + "/auto.cnf"])?.path == data)
        #expect(location(.mysql, ["mysqld", "--datadir=" + data]) == nil)
    }

    @Test("Redis: its title hides everything, so its working folder says; never home or /")
    func redis() {
        // Redis rewrites its arguments to this, and moves into its `dir`.
        let title = ["/opt/homebrew/opt/redis/bin/redis-server *:6379"]
        #expect(location(.redis, title, cwd: "/opt/homebrew/var/db/redis")?.path == "/opt/homebrew/var/db/redis")
        #expect(location(.redis, title, cwd: "/opt/homebrew/var/db/redis")?.source == .workingDirectory)
        #expect(location(.redis, title, cwd: home) == nil)
        #expect(location(.redis, title, cwd: "/") == nil)
        #expect(location(.redis, title, cwd: home + "/") == nil)
        #expect(location(.redis, ["redis-server", "--dir", "/data/r"], cwd: home)?.path == "/data/r")
        #expect(location(.redis, ["redis-server", "--dir", "/data/r"], cwd: home)?.source == .arguments)
        // Home, by argument: still no.
        #expect(location(.redis, ["redis-server", "--dir", home], cwd: "/x") == nil)
    }

    @Test("Redis counts its own files, however it's named them: it may share a folder with anything")
    func redisFiles() {
        #expect(LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server *:6379"]) == [
            "dump.rdb",
            "appendonly.aof",
            "appendonlydir",
        ])
        #expect(LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server", "--dbfilename", "x.rdb"])?.first == "x.rdb")
        // A path in a file name can't lead out of the folder.
        #expect(LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server", "--dbfilename", "../../etc/passwd"])?
            .first == "passwd")
        #expect(LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server", "--appenddirname", ".."])?.last == "appendonlydir")
        #expect(LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server", "--dbfilename", "/"])?.first == "dump.rdb")
        #expect(LocalDatabaseRules.dataFiles(engine: .postgres, arguments: ["postgres"]) == nil)
    }

    @Test("MongoDB: --dbpath, or the config it names; its working folder says nothing")
    func mongo() {
        let data = "/opt/homebrew/var/mongodb"
        let files: Set<String> = [data + "/WiredTiger"]
        #expect(location(.mongodb, ["mongod", "--dbpath", data], files: files)?.path == data)
        #expect(location(.mongodb, ["mongod", "--dbpath=" + data], files: files)?.path == data)
        let yaml = "systemLog:\n  destination: file\nstorage:\n  # dbPath: /old\n  dbPath: \(data)\n"
        let config = ["/opt/homebrew/etc/mongod.conf": yaml]
        #expect(location(.mongodb, ["mongod", "--config", "/opt/homebrew/etc/mongod.conf"], files: files, config: config)?.path == data)
        #expect(location(.mongodb, ["mongod", "-f", "/opt/homebrew/etc/mongod.conf"], files: files, config: config)?.source == .arguments)
        #expect(location(.mongodb, ["mongod"], cwd: data, files: files) == nil)
        #expect(LocalDatabaseRules.mongoPath(config: "dbpath=/old/style\n") == "/old/style")
        #expect(LocalDatabaseRules.mongoPath(config: "storage:\n  dbPath: \"/quoted path\"\n") == "/quoted path")
        #expect(LocalDatabaseRules.mongoPath(config: "net:\n  port: 27017\n") == nil)
    }

    @Test("Homebrew's usual folder, only if there's exactly one and it's the engine's")
    func usualPlaces() {
        let first = "/opt/homebrew/var/postgresql@16"
        let second = "/opt/homebrew/var/postgresql@15"
        let one: Set<String> = [first, first + "/PG_VERSION"]
        #expect(location(.postgres, [], cwd: "/", files: one)?.path == first)
        #expect(location(.postgres, [], cwd: "/", files: one)?.source == .usualPlace)
        let two: Set<String> = [first, first + "/PG_VERSION", second, second + "/PG_VERSION"]
        #expect(location(.postgres, [], cwd: "/", files: two) == nil)
        #expect(location(.postgres, [], cwd: "/", files: [first]) == nil)
    }

    @Test("What a database rewrites by itself isn't a sign of use")
    func background() {
        for path in [
            "postmaster.pid",
            "postmaster.opts",
            "pg_stat_tmp/global.stat",
            "pg_stat/x",
            "log/postgresql.log",
            "base/pgsql_tmp/t",
            "pg_log/a",
        ] {
            #expect(LocalDatabaseRules.isBackgroundFile(.postgres, path), "\(path)")
        }
        for path in ["base/16384/2619", "global/1262", "pg_wal/000000010000000000000001", "PG_VERSION"] {
            #expect(!LocalDatabaseRules.isBackgroundFile(.postgres, path), "\(path)")
        }
        for path in ["mac.err", "mac.pid", "ib_buffer_pool", "#innodb_temp/temp_1.ibt", "ibtmp1", "general.log"] {
            #expect(LocalDatabaseRules.isBackgroundFile(.mysql, path), "\(path)")
        }
        #expect(!LocalDatabaseRules.isBackgroundFile(.mysql, "shop/orders.ibd"))
        for path in [
            "diagnostic.data/metrics.2026",
            "journal/WiredTigerLog.1",
            "mongod.lock",
            "WiredTiger.turtle",
            "WiredTiger.wt",
            "sizeStorer.wt",
        ] {
            #expect(LocalDatabaseRules.isBackgroundFile(.mongodb, path), "\(path)")
        }
        #expect(!LocalDatabaseRules.isBackgroundFile(.mongodb, "collection-2-123.wt"))
        #expect(!LocalDatabaseRules.isBackgroundFile(.redis, "dump.rdb"))
    }

    private func activity(
        connections: Int? = 0, readable: Bool = true, write: Double? = nil, known: Bool = true, busy: Double? = nil, history: Double? = 90
    ) -> LocalDatabaseRules.Activity {
        LocalDatabaseRules.activity(
            connections: connections, isReadable: readable, lastWrite: write.map { now.addingTimeInterval(-$0 * 86400) }, dataKnown: known,
            lastBusy: busy.map { now.addingTimeInterval(-$0 * 86400) }, historySince: history.map { now.addingTimeInterval(-$0 * 86400) },
            now: now
        )
    }

    private func date(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    @Test("A connection now beats everything")
    func inUse() {
        #expect(activity(connections: 1, write: 400, busy: 400) == .inUseNow)
    }

    @Test("Used lately: the newer of a write and a busy hour")
    func recent() {
        #expect(activity(write: 3, busy: 20) == .lastUsed(date(3)))
        #expect(activity(write: 20, busy: 3) == .lastUsed(date(3)))
        #expect(activity(write: 1) == .lastUsed(date(1)))
    }

    @Test("Quiet needs both kinds of evidence, each over two weeks")
    func quiet() {
        #expect(activity(write: 30, busy: 40) == .quiet(since: date(30)))
        #expect(activity(write: 40) == .quiet(since: date(40)))
        // Never written since it was sized, never busy, with the history to say so.
        #expect(activity() == .quiet(since: nil))
        #expect(activity(write: 14, busy: 14) == .quiet(since: date(14)))
        #expect(activity(write: 13.9, busy: 30) == .lastUsed(date(13.9)))
    }

    @Test("Never quiet without the evidence: a new History, no data folder, or unreadable")
    func notEnough() {
        #expect(activity(write: 30, history: 5) == .lastUsed(date(30)))
        #expect(activity(write: 30, history: nil) == .lastUsed(date(30)))
        #expect(activity(history: 5) == .unknown)
        #expect(activity(known: false, busy: 30) == .lastUsed(date(30)))
        #expect(activity(known: false) == .unknown)
        #expect(activity(readable: false, write: 30) == .lastUsed(date(30)))
        #expect(activity(connections: nil) == .unknown)
    }

    @Test("A busy hour is 1% of a core or more, the newest one")
    func busy() {
        func point(_ days: Double, _ average: Double) -> SeriesPoint {
            SeriesPoint(at: date(days), average: average, maximum: average)
        }
        #expect(LocalDatabaseRules.lastBusy([point(9, 2), point(5, 1), point(1, 0.4)]) == date(5))
        #expect(LocalDatabaseRules.lastBusy([point(1, 0.2)]) == nil)
        #expect(LocalDatabaseRules.lastBusy([]) == nil)
    }

    @Test("PostgreSQL's backends are its main process's, and two servers stay two")
    func mainProcesses() {
        let table: [(pid: Int32, parentPID: Int32, engine: DatabaseEngine)] = [
            (100, 1, .postgres), (101, 100, .postgres), (102, 100, .postgres), (103, 102, .postgres),
            (200, 1, .postgres), (201, 200, .postgres),
            // Started by a shell or a safe script: its own main process.
            (300, 299, .mysql), (400, 1, .redis),
        ]
        let main = LocalDatabaseRules.mainProcesses(table)
        #expect(main.map(\.pid) == [100, 200, 300, 400])
        #expect(main[0].members == [100, 101, 102, 103])
        #expect(main[1].members == [200, 201])
        #expect(main[2].members == [300])
    }

    @Test("The most memory first")
    func sorted() {
        func database(_ pid: Int32, _ memory: UInt64) -> LocalDatabase {
            LocalDatabase(
                pid: pid, engine: .redis, pids: [pid], memoryBytes: memory, startedAt: nil, ports: [], dataDirectory: nil, dataSource: nil,
                connections: nil, isReadable: true, processName: "redis-server"
            )
        }
        #expect(LocalDatabaseRules.sorted([database(1, 5), database(2, 50), database(3, 5)]).map(\.pid) == [2, 1, 3])
    }
}
