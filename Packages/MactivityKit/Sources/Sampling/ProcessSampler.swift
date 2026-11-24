import Core
import Darwin
import Foundation

/// Every readable process, with cumulative counters (spec 6.1). Public API only.
///
/// One `sysctl(KERN_PROC_ALL)` into a reused buffer returns the whole process table (pid, parent, uid, name, start
/// time), then `proc_pid_rusage` reads each process's counters. That is one kernel call per
/// process instead of two, which matters: kernel calls were most of the idle cost
/// (D-022). Processes the kernel refuses come back with
/// `isComplete == false` and zero counters; the sampler gives their share to the macOS row.
public actor ProcessSampler: ProcessSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private struct Key: Hashable {
        let pid: Int32
        let start: Date
    }

    /// Mach time → nanoseconds. `ri_user_time` / `ri_system_time` are in Mach absolute time
    /// units on Apple silicon, not nanoseconds.
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    /// Executable path and display name, read once per process, and again if its short name
    /// changes: `exec` keeps the PID and start time but swaps the program. launchd starts every job
    /// as xpcproxy, which execs the real one a moment later; caught in between, a Homebrew
    /// service stayed "xpcproxy" under macOS for life (D-142). `comm` is a hash of `p_comm`.
    private var identities: [Key: (path: String?, name: String, comm: Int)] = [:]
    /// Processes `proc_pid_rusage` refused. Permission doesn't change for the life of a process,
    /// so don't ask again every tick.
    private var refused: Set<Key> = []

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(max(1, info.numer))
        timebaseDenom = UInt64(max(1, info.denom))
    }

    public func sample() async throws -> [ProcessReading] {
        read(skipping: [])
    }

    public func sample(skippingUsageFor pids: Set<Int32>) async throws -> [ProcessReading] {
        read(skipping: pids)
    }

    private func read(skipping: Set<Int32>) -> [ProcessReading] {
        let count = fillProcessTable()
        var readings: [ProcessReading] = []
        readings.reserveCapacity(count)
        var seen = Set<Key>()
        seen.reserveCapacity(count)
        table.withUnsafeBufferPointer { procs in
            for info in procs.prefix(count) {
                let proc = info.kp_proc
                guard proc.p_stat != SZOMB, proc.p_pid >= 0 else {
                    continue
                }
                let started = proc.p_un.__p_starttime
                let entry = TableEntry(
                    pid: proc.p_pid,
                    parentPID: info.kp_eproc.e_ppid,
                    uid: info.kp_eproc.e_ucred.cr_uid,
                    start: Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
                )
                let key = Key(pid: entry.pid, start: entry.start)
                seen.insert(key)
                // The name is decoded only the first time a process is seen; after that the
                // cached identity has it.
                // Skipped only if seen before: the set is by PID, and a new process that reuses
                // a macOS daemon's PID would otherwise read as 0 MB for a tick (D-138).
                var comm = proc.p_comm
                let commHash = withUnsafeBytes(of: &comm) { bytes in
                    var hasher = Hasher()
                    hasher.combine(bytes: bytes)
                    return hasher.finalize()
                }
                readings.append(reading(
                    for: entry, key: key, skipUsage: skipping.contains(entry.pid) && identities[key] != nil,
                    commHash: commHash, shortName: { Self.string(fromTuple: proc.p_comm) }
                ))
            }
        }
        // Forget processes that exited.
        if identities.count > seen.count * 2 {
            identities = identities.filter { seen.contains($0.key) }
        }
        if refused.count > seen.count {
            refused = refused.intersection(seen)
        }
        return readings
    }

    private struct TableEntry {
        let pid: Int32
        let parentPID: Int32
        let uid: UInt32
        let start: Date
    }

    /// The kernel's process table, kept between passes. Asking for the size first walks every
    /// process in the kernel a second time, so read straight into the buffer we have and only
    /// ask (and grow, with headroom) when it's too small. Returns how many entries are valid.
    private var table: [kinfo_proc] = []

    private func fillProcessTable() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // Three rounds covers processes starting between the size query and the read.
        for _ in 0 ..< 3 {
            if !table.isEmpty {
                var size = table.count * stride
                let status = table.withUnsafeMutableBytes { buffer in
                    sysctl(&mib, 4, buffer.baseAddress, &size, nil, 0)
                }
                if status == 0 {
                    return size / stride
                }
                guard errno == ENOMEM else {
                    return 0
                }
            }
            var needed = 0
            guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0, needed > 0 else {
                return 0
            }
            table = [kinfo_proc](repeating: kinfo_proc(), count: (needed + needed / 4) / stride + 16)
        }
        return 0
    }

    private func reading(
        for entry: TableEntry, key: Key, skipUsage: Bool, commHash: Int, shortName: () -> String
    ) -> ProcessReading {
        let identity: (path: String?, name: String, comm: Int)
        if let cached = identities[key], cached.comm == commHash {
            identity = cached
        } else {
            let path = Self.executablePath(entry.pid)
            // `p_comm` stops at 16 characters; the executable's file name doesn't. Split the
            // string by hand: `URL(fileURLWithPath:)` stats the file.
            var name = shortName()
            if name.utf8.count >= Int(MAXCOMLEN), let path, let last = path.split(separator: "/").last {
                name = String(last)
            }
            identity = (path, name, commHash)
            identities[key] = identity
        }
        let (path, name, _) = identity

        var usage = rusage_info_v6()
        var complete = false
        if !skipUsage, !refused.contains(key) {
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(entry.pid, RUSAGE_INFO_V6, $0)
                }
            }
            complete = status == 0
            if !complete, errno == EPERM {
                refused.insert(key)
            }
        }
        let cpuNanoseconds = complete ? nanoseconds(machTime: usage.ri_user_time &+ usage.ri_system_time) : 0
        return ProcessReading(
            pid: entry.pid,
            parentPID: entry.parentPID,
            uid: entry.uid,
            name: name,
            executablePath: path,
            startTime: entry.start,
            cpuTime: .nanoseconds(Int64(clamping: cpuNanoseconds)),
            footprintBytes: complete ? usage.ri_phys_footprint : 0,
            diskReadBytes: complete ? usage.ri_diskio_bytesread : 0,
            diskWriteBytes: complete ? usage.ri_diskio_byteswritten : 0,
            // The process's own energy. `ri_billed_energy` only counts work billed to it by other
            // processes: 0 for a process spinning a core at 6.7 W (D-109).
            energyNJ: complete ? usage.ri_energy_nj : 0,
            isComplete: complete,
            wakeups: complete ? usage.ri_interrupt_wkups &+ usage.ri_pkg_idle_wkups : 0
        )
    }

    private func nanoseconds(machTime: UInt64) -> UInt64 {
        // Split to avoid overflow: machTime × numer can exceed UInt64 for long-lived processes.
        machTime / timebaseDenom * timebaseNumer + machTime % timebaseDenom * timebaseNumer / timebaseDenom
    }

    /// `proc_pidpath`, or when that refuses (a sandboxed app extension like Excel's widget, which
    /// then showed as an app of its own) the exec path from `KERN_PROCARGS2`, as `ps` does
    /// (D-111). Read once per process: the sampler caches identities.
    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return execPathFromArguments(pid)
        }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func execPathFromArguments(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return execPath(procArgs: bytes.prefix(size))
    }

    /// Pure: the exec path in a `KERN_PROCARGS2` buffer, which starts with argc (an Int32), then
    /// the NUL-terminated path the process was started from. Nil unless it's absolute.
    static func execPath(procArgs: some Collection<UInt8>) -> String? {
        let path = procArgs.dropFirst(MemoryLayout<Int32>.size).prefix { $0 != 0 }
        guard path.first == UInt8(ascii: "/") else {
            return nil
        }
        return String(bytes: path, encoding: .utf8)
    }

    /// C fixed-size `char[]` fields import as tuples.
    private static func string(fromTuple tuple: some Any) -> String {
        withUnsafeBytes(of: tuple) { raw in
            // Swift's own UTF-8 decoding: several times cheaper than Foundation's, on every
            // process every pass. Lossy on purpose: a bad byte shows as U+FFFD, not an empty name.
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
