import Darwin
import Dispatch
import Foundation
import os
import Synchronization

/// Per-process network byte counters from `NetworkStatistics.framework`, the private framework
/// `nettop` is built on (spec 6.5 option a).
///
/// One manager subscribes to every TCP and UDP socket the kernel will report to us. The kernel
/// pushes "source added" and "source removed" as sockets come and go; a query asks it for fresh
/// counts on every live source. Bytes from sockets that closed between two queries are kept in a
/// per-process ledger, so a short connection's bytes still count.
///
/// Measured on macOS 27.0 (26A428), unentitled (nettop has `com.apple.private.network.statistics`,
/// we don't):
/// - Every symbol below resolves, and the manager works without root.
/// - The kernel only reports sockets owned by the calling user. Root and other-user daemons
///   (mDNSResponder, apsd, syslogd, netbiosd) are invisible, so callers treat their rates as unknown.
/// - Flows on the user-space network stack aren't reported either. On this Mac that's
///   `com.apple.WebKit.Networking` (15 flows in nettop, none here, no socket file descriptors in
///   lsof). Safari's page loads are missing per app; the system-wide figure still has them.
/// - A source added after we subscribed gets its description (PID, unique PID, loopback) by
///   itself. The sockets that were already open when we subscribed don't: their counts arrive
///   without a PID until one `NStatManagerQueryAllSourcesUpdate` describes them. So the first
///   query, and any query while an undescribed source exists, is an update; every other query
///   asks for counts only (`NStatManagerQueryAllSources`). Once described, the framework keeps
///   the PID in every counts dictionary. Counts-only costs about 0.24 ms of CPU per query over
///   ~50 sources, an update about 0.42 ms.
public final class NetworkStatisticsMonitor: Sendable {
    /// Cumulative bytes received and sent, by PID.
    public typealias Totals = [Int32: (rx: UInt64, tx: UInt64)]

    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "nstat")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    typealias SourceAddedBlock = @convention(block) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    typealias DictionaryBlock = @convention(block) (CFDictionary?) -> Void
    typealias VoidBlock = @convention(block) () -> Void
    // The framework keeps every block it's given (copies it), so each one is @escaping.
    typealias CreateManager = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceAddedBlock) -> OpaquePointer?
    typealias ManagerCall = @convention(c) (OpaquePointer) -> Void
    typealias ManagerQuery = @convention(c) (OpaquePointer, @escaping VoidBlock) -> Void
    typealias SetDictionaryBlock = @convention(c) (OpaquePointer, @escaping DictionaryBlock) -> Void
    typealias SetVoidBlock = @convention(c) (OpaquePointer, @escaping VoidBlock) -> Void

    struct Keys: @unchecked Sendable {
        // CFStrings are immutable constants exported by the framework.
        let pid: CFString
        let uniquePID: CFString
        let rxBytes: CFString
        let txBytes: CFString
        let loopback: CFString
    }

    struct Functions: @unchecked Sendable {
        // C function pointers into a framework that is never unloaded.
        let create: CreateManager
        let destroy: ManagerCall
        let addAllTCP: ManagerCall
        let addAllUDP: ManagerCall
        let queryCounts: ManagerQuery
        let queryUpdate: ManagerQuery
        let setCountsBlock: SetDictionaryBlock
        let setDescriptionBlock: SetDictionaryBlock
        let setRemovedBlock: SetVoidBlock
        let keys: Keys
    }

    /// Resolved once with `dlopen` + `dlsym`.
    ///
    /// - Symbols: `NStatManagerCreate`, `NStatManagerDestroy`, `NStatManagerAddAllTCP`,
    ///   `NStatManagerAddAllUDP`, `NStatManagerQueryAllSources`, `NStatManagerQueryAllSourcesUpdate`,
    ///   `NStatSourceSetCountsBlock`,
    ///   `NStatSourceSetDescriptionBlock`, `NStatSourceSetRemovedBlock`, and the dictionary keys
    ///   `kNStatSrcKeyPID`, `kNStatSrcKeyUPID`, `kNStatSrcKeyRxBytes`, `kNStatSrcKeyTxBytes`,
    ///   `kNStatSrcKeyInterfaceTypeLoopback`.
    /// - Framework: `/System/Library/PrivateFrameworks/NetworkStatistics.framework` (private, no
    ///   headers; the signatures are the ones `nettop` links against).
    /// - If Apple removes or changes them: any missing symbol makes this nil, the monitor reports
    ///   nil, and per-app network rates stay nil. The Network tab then shows system-wide figures
    ///   and says per-app figures are unavailable (the spec 6.5 fallback). A changed signature
    ///   would crash rather than fail, which is why the live test runs on every macOS we ship on.
    static let functions: Functions? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            log.notice("NetworkStatistics.framework unavailable; per-app network rates off")
            return nil
        }
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        func key(_ name: String) -> CFString? {
            dlsym(handle, name).map { $0.load(as: Unmanaged<CFString>.self).takeUnretainedValue() }
        }
        guard let create = resolve("NStatManagerCreate", as: CreateManager.self),
              let destroy = resolve("NStatManagerDestroy", as: ManagerCall.self),
              let addAllTCP = resolve("NStatManagerAddAllTCP", as: ManagerCall.self),
              let addAllUDP = resolve("NStatManagerAddAllUDP", as: ManagerCall.self),
              let queryCounts = resolve("NStatManagerQueryAllSources", as: ManagerQuery.self),
              let queryUpdate = resolve("NStatManagerQueryAllSourcesUpdate", as: ManagerQuery.self),
              let setCounts = resolve("NStatSourceSetCountsBlock", as: SetDictionaryBlock.self),
              let setDescription = resolve("NStatSourceSetDescriptionBlock", as: SetDictionaryBlock.self),
              let setRemoved = resolve("NStatSourceSetRemovedBlock", as: SetVoidBlock.self),
              let pid = key("kNStatSrcKeyPID"),
              let uniquePID = key("kNStatSrcKeyUPID"),
              let rxBytes = key("kNStatSrcKeyRxBytes"),
              let txBytes = key("kNStatSrcKeyTxBytes"),
              let loopback = key("kNStatSrcKeyInterfaceTypeLoopback")
        else {
            log.notice("NetworkStatistics symbols missing; per-app network rates off")
            return nil
        }
        return Functions(
            create: create, destroy: destroy, addAllTCP: addAllTCP, addAllUDP: addAllUDP,
            queryCounts: queryCounts, queryUpdate: queryUpdate, setCountsBlock: setCounts, setDescriptionBlock: setDescription,
            setRemovedBlock: setRemoved,
            keys: Keys(pid: pid, uniquePID: uniquePID, rxBytes: rxBytes, txBytes: txBytes, loopback: loopback)
        )
    }()

    /// How long a query may take before we use what we have.
    static let queryTimeout: DispatchTimeInterval = .milliseconds(250)

    /// The ledger behind a lock. Callbacks write it on `queue`; readers take a copy of the totals.
    final class Storage: Sendable {
        let ledger = Mutex(NetworkStatisticsLedger())
    }

    /// Resumes a continuation once, whichever of the query's completion or the timeout comes first.
    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<Void, Never>?>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume() {
            continuation.withLock { $0.take() }?.resume()
        }
    }

    private let functions: Functions?
    /// The `NStatManagerRef`, as a bit pattern; only touched through `functions`.
    private let manager: UInt
    private let queue: DispatchQueue
    private let storage: Storage

    /// Subscribes to every TCP and UDP socket. The subscription lives as long as the monitor.
    public convenience init() {
        self.init(functions: Self.functions)
    }

    /// Testable seam: pass nil to exercise the fallback path.
    init(functions: Functions?) {
        let queue = DispatchQueue(label: "app.mactivity.privateapis.nstat", qos: .utility)
        let storage = Storage()
        self.queue = queue
        self.storage = storage
        guard let functions else {
            self.functions = nil
            manager = 0
            return
        }
        let added: SourceAddedBlock = { source, _ in
            guard let source else {
                return
            }
            Self.watch(source, functions: functions, storage: storage)
        }
        guard let created = functions.create(kCFAllocatorDefault, queue, added) else {
            Self.log.notice("NStatManagerCreate returned nil; per-app network rates off")
            self.functions = nil
            manager = 0
            return
        }
        self.functions = functions
        manager = UInt(bitPattern: created)
        functions.addAllTCP(created)
        functions.addAllUDP(created)
    }

    deinit {
        if let functions, let manager = OpaquePointer(bitPattern: manager) {
            functions.destroy(manager)
        }
    }

    /// Whether the private framework resolved and the manager was created.
    public var isAvailable: Bool {
        functions != nil
    }

    /// Cumulative bytes per PID since we started watching, including sockets that have closed.
    /// Nil when NetworkStatistics is unavailable. Waits at most `queryTimeout` for the kernel;
    /// don't call it from a thread that must not block, use `cumulativeBytes()` there.
    public func cumulativeBytesByPID() -> Totals? {
        guard let functions, let manager = OpaquePointer(bitPattern: manager) else {
            return nil
        }
        let done = DispatchSemaphore(value: 0)
        query(manager, functions: functions) { done.signal() }
        if done.wait(timeout: .now() + Self.queryTimeout) == .timedOut {
            Self.log.notice("NetworkStatistics query timed out; using the last counts")
        }
        return totals()
    }

    /// Same as `cumulativeBytesByPID()`, without blocking the caller's thread.
    public func cumulativeBytes() async -> Totals? {
        guard let functions, let manager = OpaquePointer(bitPattern: manager) else {
            return nil
        }
        let queue = queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            // A cancellable timer rather than asyncAfter, so an answered query leaves no wakeup behind.
            let timeout = DispatchSource.makeTimerSource(queue: queue)
            timeout.schedule(deadline: .now() + Self.queryTimeout)
            timeout.setEventHandler { once.resume() }
            timeout.resume()
            query(manager, functions: functions) {
                timeout.cancel()
                once.resume()
            }
        }
        return totals()
    }

    /// Counts only, unless a source still needs its description (see the type's notes).
    private func query(_ manager: OpaquePointer, functions: Functions, completion: @escaping VoidBlock) {
        if storage.ledger.withLock({ $0.needsDescriptions }) {
            functions.queryUpdate(manager, completion)
        } else {
            functions.queryCounts(manager, completion)
        }
    }

    private func totals() -> Totals {
        storage.ledger.withLock { ledger in
            ledger.pruneClosed(isAlive: Self.isAlive)
            return ledger.totals()
        }
    }

    /// The process that closed those sockets is still running: its PID is in use, by a process
    /// that started before they closed, not a later one that reused the PID (D-221).
    static func isAlive(_ pid: Int32, closedAt: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return kill(pid, 0) == 0 || errno != ESRCH
        }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) <= closedAt
    }

    /// Sets the per-source callbacks. They run on the manager's queue.
    private static func watch(_ source: OpaquePointer, functions: Functions, storage: Storage) {
        let id = UInt(bitPattern: source)
        let keys = functions.keys
        func update(isDescription: Bool) -> DictionaryBlock {
            { dictionary in
                guard let dictionary else {
                    return
                }
                let reading = NetworkStatisticsLedger.Reading(
                    pid: number(dictionary, keys.pid).map { Int32(truncatingIfNeeded: $0) },
                    uniquePID: number(dictionary, keys.uniquePID).map { UInt64(bitPattern: $0) },
                    rx: number(dictionary, keys.rxBytes).map { UInt64(bitPattern: $0) },
                    tx: number(dictionary, keys.txBytes).map { UInt64(bitPattern: $0) },
                    loopback: number(dictionary, keys.loopback).map { $0 != 0 },
                    isDescription: isDescription
                )
                storage.ledger.withLock { $0.update(source: id, with: reading) }
            }
        }
        functions.setCountsBlock(source, update(isDescription: false))
        functions.setDescriptionBlock(source, update(isDescription: true))
        functions.setRemovedBlock(source) {
            storage.ledger.withLock { $0.remove(source: id) }
        }
    }

    /// A 64-bit integer from a CF dictionary without bridging it to Swift.
    private static func number(_ dictionary: CFDictionary, _ key: CFString) -> Int64? {
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else {
            return nil
        }
        let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        switch CFGetTypeID(object) {
        case CFBooleanGetTypeID():
            return CFBooleanGetValue(unsafeDowncast(object, to: CFBoolean.self)) ? 1 : 0
        case CFNumberGetTypeID():
            var value: Int64 = 0
            return CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .sInt64Type, &value) ? value : nil
        default:
            return nil
        }
    }
}

/// The bookkeeping behind `NetworkStatisticsMonitor`: the latest counts for every live socket,
/// plus the final counts of sockets that closed, per process. Pure, so it's tested with fixtures.
struct NetworkStatisticsLedger: Sendable {
    /// What one callback said about one source. Any field can be missing from a given callback.
    struct Reading: Hashable, Sendable, Codable {
        var pid: Int32?
        /// `uniqueProcessID`: never reused, unlike a PID.
        var uniquePID: UInt64?
        var rx: UInt64?
        var tx: UInt64?
        var loopback: Bool?
        /// From the description callback rather than a counts one.
        var isDescription = false
    }

    struct Source: Hashable, Sendable {
        var pid: Int32 = 0
        var uniquePID: UInt64 = 0
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var loopback = false
        var described = false
    }

    struct Closed: Hashable, Sendable {
        var uniquePID: UInt64
        var rx: UInt64
        var tx: UInt64
        /// When the last of them closed: a process on this PID that started later is another one.
        var closedAt: Date
    }

    private(set) var sources: [UInt: Source] = [:]
    private(set) var closed: [Int32: Closed] = [:]

    mutating func update(source id: UInt, with reading: Reading) {
        var source = sources[id] ?? Source()
        if let pid = reading.pid, pid > 0 {
            source.pid = pid
        }
        if let uniquePID = reading.uniquePID {
            source.uniquePID = uniquePID
        }
        // Counts on one socket only grow; a smaller number is an out-of-order callback.
        if let rx = reading.rx {
            source.rx = max(source.rx, rx)
        }
        if let tx = reading.tx {
            source.tx = max(source.tx, tx)
        }
        if let loopback = reading.loopback {
            source.loopback = loopback
        }
        source.described = source.described || reading.isDescription
        sources[id] = source
        // A new process on a reused PID: the old one's closed bytes aren't its bytes.
        if source.pid > 0, source.uniquePID != 0, let old = closed[source.pid], old.uniquePID != source.uniquePID {
            closed[source.pid] = nil
        }
    }

    /// True while some source hasn't been described yet (or before the first source arrives), so
    /// its counts carry no PID.
    var needsDescriptions: Bool {
        sources.isEmpty || sources.values.contains { !$0.described }
    }

    /// The socket closed. Its last counts move into the process's closed total.
    mutating func remove(source id: UInt, at now: Date = Date()) {
        guard let source = sources.removeValue(forKey: id), source.pid > 0, !source.loopback, source.rx > 0 || source.tx > 0 else {
            return
        }
        if var total = closed[source.pid], total.uniquePID == source.uniquePID {
            total.rx &+= source.rx
            total.tx &+= source.tx
            total.closedAt = now
            closed[source.pid] = total
        } else {
            closed[source.pid] = Closed(uniquePID: source.uniquePID, rx: source.rx, tx: source.tx, closedAt: now)
        }
    }

    /// Drops closed totals for processes that have exited and have no live sockets, including
    /// those whose PID a new process now has.
    mutating func pruneClosed(isAlive: (_ pid: Int32, _ closedAt: Date) -> Bool) {
        guard !closed.isEmpty else {
            return
        }
        let live = Set(sources.values.map(\.pid))
        for (pid, total) in closed where !live.contains(pid) && !isAlive(pid, total.closedAt) {
            closed[pid] = nil
        }
    }

    /// Bytes per PID: live sockets plus closed ones. Loopback traffic is left out, like the
    /// system-wide figure, which only counts physical interfaces.
    func totals() -> [Int32: (rx: UInt64, tx: UInt64)] {
        var totals: [Int32: (rx: UInt64, tx: UInt64)] = [:]
        for source in sources.values where source.pid > 0 && !source.loopback {
            let total = totals[source.pid] ?? (0, 0)
            totals[source.pid] = (total.rx &+ source.rx, total.tx &+ source.tx)
        }
        for (pid, total) in closed {
            let sum = totals[pid] ?? (0, 0)
            totals[pid] = (sum.rx &+ total.rx, sum.tx &+ total.tx)
        }
        return totals
    }
}
