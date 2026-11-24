import Core
import Darwin
import Foundation

/// Local databases from the process table (D-277). Names, sockets and folder metadata: it never
/// connects to a database and never opens anything in a data folder. The one file it reads is
/// the MongoDB config file named in `mongod`'s arguments, for its `dbPath` line.
public struct LiveLocalDatabases: LocalDatabaseSource {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func databases() async -> [LocalDatabase] {
        let home = home
        return await Task.detached(priority: .utility) { Self.read(home: home) }.value
    }

    public func diskUse(of database: LocalDatabase) async -> DatabaseDiskUse? {
        guard let directory = database.dataDirectory else {
            return nil
        }
        let arguments = ProcessInspector.arguments(database.pid)
        // Stops with the view: the walk checks for it in every folder.
        let walk = Task.detached(priority: .utility) {
            let files = LocalDatabaseRules.dataFiles(engine: database.engine, arguments: arguments)
            return DataFolderWalk.measure(directory, only: files) { LocalDatabaseRules.isBackgroundFile(database.engine, $0) }
        }
        return await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
    }

    static func read(home: String) -> [LocalDatabase] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        var table: [(pid: Int32, parentPID: Int32, engine: DatabaseEngine)] = []
        var identities: [Int32: ProcessInspector.Identity] = [:]
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard let identity = ProcessInspector.identity(pid), let engine = DatabaseEngine(processName: identity.name) else {
                continue
            }
            identities[pid] = identity
            table.append((pid, identity.parentPID, engine))
        }
        let engines = Dictionary(table.map { ($0.pid, $0.engine) }, uniquingKeysWith: { first, _ in first })
        let found = LocalDatabaseRules.mainProcesses(table).compactMap { main -> LocalDatabase? in
            guard let engine = engines[main.pid], let identity = identities[main.pid] else {
                return nil
            }
            return database(main.pid, members: main.members, engine: engine, identity: identity, home: home)
        }
        return LocalDatabaseRules.sorted(found)
    }

    private static func database(
        _ pid: Int32, members: [Int32], engine: DatabaseEngine, identity: ProcessInspector.Identity, home: String
    ) -> LocalDatabase {
        var memory: UInt64 = 0
        var readable = false
        for member in members {
            if let usage = ProcessInspector.usage(member) {
                memory &+= usage.footprint
                readable = true
            }
        }
        let ports = Array(Set(ProcessInspector.listeningPorts(pid).map(\.port))).sorted()
        let location = LocalDatabaseRules.dataDirectory(
            engine: engine, arguments: ProcessInspector.arguments(pid), workingDirectory: ProcessInspector.workingDirectory(pid),
            home: home,
            readFile: { path in
                // At most a screenful of config: a dbPath line, not a file of any size.
                guard let handle = FileHandle(forReadingAtPath: path), let data = try? handle.read(upToCount: 64 * 1024) else {
                    return nil
                }
                return String(bytes: data, encoding: .utf8)
            },
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        return LocalDatabase(
            pid: pid, engine: engine, pids: members, memoryBytes: memory, startedAt: identity.startedAt, ports: ports,
            dataDirectory: location?.path, dataSource: location?.source,
            connections: readable ? members.reduce(0) { $0 + connections($1, ports: ports) } : nil, isReadable: readable,
            processName: identity.name
        )
    }

    /// Open connections: TCP established on one of its ports, plus connected Unix sockets, which
    /// a local `psql` uses. Says only "in use now", so at worst a count too high keeps it off the
    /// quiet list.
    private static func connections(_ pid: Int32, ports: [UInt16]) -> Int {
        let tcp = ProcessInspector.inetSockets(pid).filter { $0.state == .established && ports.contains($0.localPort) }.count
        return tcp + ProcessInspector.connectedUnixSockets(pid)
    }
}

/// Walks a data folder for its allocated size and newest write, from `lstat` alone: no file is
/// opened. Doesn't follow links or leave its folder.
enum DataFolderWalk {
    /// `only`: just these entries of the folder (Redis, which shares one with anything).
    /// `isBackground` gets each file's path relative to the folder.
    static func measure(_ folder: String, only: [String]? = nil, isBackground: (String) -> Bool) -> DatabaseDiskUse? {
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, FileManager.default.isReadableFile(atPath: folder) else {
            return nil
        }
        var total: UInt64 = 0
        var newest: Date?
        for entry in only ?? (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            walk(folder + "/" + entry, relative: entry, device: info.st_dev, total: &total, newest: &newest, isBackground: isBackground)
        }
        return DatabaseDiskUse(bytes: total, lastWrite: newest)
    }

    private static func walk(
        _ path: String, relative: String, device: Int32, total: inout UInt64, newest: inout Date?, isBackground: (String) -> Bool
    ) {
        var info = stat()
        guard !Task.isCancelled, lstat(path, &info) == 0, info.st_dev == device else {
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                walk(
                    path + "/" + entry, relative: relative + "/" + entry, device: device, total: &total, newest: &newest,
                    isBackground: isBackground
                )
            }
        case S_IFREG:
            total &+= UInt64(max(0, info.st_blocks)) * 512
            if !isBackground(relative) {
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                newest = max(newest ?? modified, modified)
            }
        default:
            break
        }
    }
}

extension ProcessInspector {
    /// Unix sockets connected to something; a listening one isn't.
    static func connectedUnixSockets(_ pid: Int32) -> Int {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return 0
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else {
            return 0
        }
        var count = 0
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_kind == SOCKINFO_UN else {
                continue
            }
            if info.psi.soi_proto.pri_un.unsi_conn_pcb != 0 {
                count += 1
            }
        }
        return count
    }
}
