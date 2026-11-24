import Core
import Darwin
import Foundation

/// Per-process reads for the Projects scan (spec 6.12). Public APIs only; each call is cheap,
/// and only the user's own processes outside app bundles get this far.
enum ProcessInspector {
    struct Basics {
        let name: String
        let processGroupID: Int32
        let startedAt: Date
    }

    /// TCP ports this process is listening on (`PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`).
    static func listeningPorts(_ pid: Int32) -> [ListeningPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return []
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else {
            return []
        }
        var ports: [ListeningPort] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP
            else {
                continue
            }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else {
                continue
            }
            let inet = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            let isIPv6 = inet.insi_vflag & UInt8(INI_IPV6) != 0
            ports.append(ListeningPort(
                pid: pid, port: port, transport: isIPv6 ? .tcp6 : .tcp4,
                address: address(inet, isIPv6: isIPv6), workingDirectory: nil
            ))
        }
        return ports
    }

    private static func address(_ inet: in_sockinfo, isIPv6: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let laddr = inet.insi_laddr
        let length = MemoryLayout.size(ofValue: laddr)
        let result: UnsafePointer<CChar>? = withUnsafeBytes(of: laddr) { raw in
            guard let base = raw.baseAddress, raw.count == length else {
                return nil
            }
            if isIPv6 {
                return inet_ntop(AF_INET6, base, &buffer, socklen_t(buffer.count))
            }
            // in4in6_addr: 12 bytes of padding, then the IPv4 address.
            return inet_ntop(AF_INET, base + 12, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else {
            return "*"
        }
        let text = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "*"
        return text == "0.0.0.0" || text == "::" ? "*" : text
    }

    /// The process's current directory (`PROC_PIDVNODEPATHINFO` → `pvi_cdir`).
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
        }
        return path?.isEmpty == false ? path : nil
    }

    static func basics(_ pid: Int32) -> Basics? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        var name = withUnsafeBytes(of: info.pbi_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbi_comm) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        }
        return Basics(
            name: name,
            processGroupID: Int32(bitPattern: info.pbi_pgid),
            startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        )
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    /// argv via `sysctl(KERN_PROCARGS2)`.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return []
        }
        return ProjectDetection.parseProcArgs(Array(buffer.prefix(size)))?.arguments ?? []
    }

    /// PIDs in a process group.
    static func members(ofGroup group: Int32) -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: group), nil, 0)
        guard bytes > 0 else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 16)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: group), buffer.baseAddress, Int32(buffer.count))
        }
        return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }
    }

    /// Footprint and total CPU time.
    /// `started` is the kernel's start time in mach ticks: with the PID, it tells a process from
    /// a later one that reused its PID.
    static func usage(_ pid: Int32) -> (footprint: UInt64, cpu: Duration, started: UInt64)? {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else {
            return nil
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let mach = usage.ri_user_time &+ usage.ri_system_time
        let nanoseconds = Double(mach) * Double(timebase.numer) / Double(max(1, timebase.denom))
        return (usage.ri_phys_footprint, .nanoseconds(Int64(clamping: UInt64(nanoseconds))), usage.ri_proc_start_abstime)
    }
}

// MARK: - Inspector reads (E12, E1)

extension ProcessInspector {
    /// `proc_bsdinfo` fields the inspector needs beyond `Basics`.
    struct Identity {
        let name: String
        let parentPID: Int32
        let uid: UInt32
        let startedAt: Date
    }

    /// Every descriptor, sorted into the kinds the inspector shows.
    struct Descriptors {
        var openFiles: [ProcessDetails.OpenFile] = []
        var sockets: [SocketEntry] = []
        var unixSockets = 0
        var other = 0
    }

    /// Name, parent, owner, and start time. `PROC_PIDTBSDINFO` works for other users' processes;
    /// `sysctl(KERN_PROC_PID)` is the fallback when it doesn't.
    static func identity(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            var name = withUnsafeBytes(of: info.pbi_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
            if name.isEmpty {
                name = withUnsafeBytes(of: info.pbi_comm) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
            }
            return Identity(
                name: name,
                parentPID: Int32(bitPattern: info.pbi_ppid),
                uid: info.pbi_uid,
                startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            )
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &process, &length, nil, 0) == 0, length == MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid
        else {
            return nil
        }
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        let start = process.kp_proc.p_un.__p_starttime
        return Identity(
            name: name,
            parentPID: process.kp_eproc.e_ppid,
            uid: process.kp_eproc.e_ucred.cr_uid,
            startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        )
    }

    /// Parent first, up to and including launchd. Stops on a loop or an unreadable parent.
    static func parentChain(of pid: Int32, parentPID: Int32) -> [ProcessDetails.Ancestor] {
        var chain: [ProcessDetails.Ancestor] = []
        var seen: Set<Int32> = [pid]
        var next = parentPID
        while next > 0, seen.insert(next).inserted, chain.count < 64, let identity = identity(next) {
            chain.append(ProcessDetails.Ancestor(pid: next, name: identity.name))
            if next == 1 {
                break
            }
            next = identity.parentPID
        }
        return chain
    }

    /// Thread count from `PROC_PIDTASKINFO`, or the errno when the kernel refuses.
    static func threadCount(_ pid: Int32) -> Result<Int, POSIXError> {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        return .success(Int(info.pti_threadnum))
    }

    /// The account name for a uid (`getpwuid_r`).
    static func userName(_ uid: UInt32) -> String? {
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var buffer = [CChar](repeating: 0, count: suggested > 0 ? suggested : 4096)
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &entry, &buffer, buffer.count, &result)
        guard status == 0, let result, let name = result.pointee.pw_name else {
            return nil
        }
        return String(cString: name)
    }

    /// Every descriptor, or the errno when `PROC_PIDLISTFDS` is refused.
    static func descriptors(_ pid: Int32) -> Result<Descriptors, POSIXError> {
        let fds: [proc_fdinfo]
        switch fileDescriptors(pid) {
        case let .success(list): fds = list
        case let .failure(error): return .failure(error)
        }
        var result = Descriptors()
        for fd in fds {
            switch fd.proc_fdtype {
            case UInt32(PROX_FDTYPE_VNODE):
                if let file = openFile(pid, fd: fd.proc_fd) {
                    result.openFiles.append(file)
                }
            case UInt32(PROX_FDTYPE_SOCKET):
                switch socket(pid, fd: fd.proc_fd) {
                case let .inet(entry): result.sockets.append(entry)
                case .unix: result.unixSockets += 1
                case .none: result.other += 1
                }
            default:
                result.other += 1
            }
        }
        return .success(result)
    }

    /// Just the TCP and UDP sockets (for connections per app, E1).
    static func inetSockets(_ pid: Int32) -> [SocketEntry] {
        guard case let .success(fds) = fileDescriptors(pid) else {
            return []
        }
        return fds.compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET), case let .inet(entry) = socket(pid, fd: fd.proc_fd) else {
                return nil
            }
            return entry
        }
    }

    /// `PROC_PIDLISTFDS`, or the errno when the kernel refuses (EPERM for other users' processes).
    private static func fileDescriptors(_ pid: Int32) -> Result<[proc_fdinfo], POSIXError> {
        errno = 0
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Headroom for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        return .success(Array(fds.prefix(Int(filled) / stride)))
    }

    /// `PROC_PIDFDVNODEPATHINFO`: the path and open mode of a vnode descriptor.
    private static func openFile(_ pid: Int32, fd: Int32) -> ProcessDetails.OpenFile? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        guard !path.isEmpty else {
            return nil
        }
        let flags = info.pfi.fi_openflags
        let reads = flags & UInt32(FREAD) != 0
        let writes = flags & UInt32(FWRITE) != 0
        let access: OpenFileAccess = reads && writes ? .readWrite : writes ? .write : .read
        return ProcessDetails.OpenFile(fd: fd, path: path, access: access)
    }

    private enum SocketKind {
        case inet(SocketEntry)
        case unix
    }

    /// `PROC_PIDFDSOCKETINFO`: TCP (with state) and UDP endpoints; Unix sockets only counted.
    private static func socket(_ pid: Int32, fd: Int32) -> SocketKind? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
            return nil
        }
        let kind = info.psi.soi_kind
        if kind == SOCKINFO_UN {
            return .unix
        }
        let inet: in_sockinfo
        let transport: SocketTransport
        var state: TCPState?
        if kind == SOCKINFO_TCP {
            inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
            transport = .tcp
            state = TCPState(kernelValue: info.psi.soi_proto.pri_tcp.tcpsi_state)
        } else if kind == SOCKINFO_IN, info.psi.soi_protocol == IPPROTO_UDP {
            inet = info.psi.soi_proto.pri_in
            transport = .udp
        } else {
            return nil
        }
        let isIPv6 = inet.insi_vflag & UInt8(INI_IPV6) != 0
        let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport))
        return .inet(SocketEntry(
            fd: fd,
            transport: transport,
            isIPv6: isIPv6,
            localAddress: endpointAddress(inet.insi_laddr, isIPv6: isIPv6),
            localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)),
            remoteAddress: remotePort == 0 ? nil : endpointAddress(inet.insi_faddr, isIPv6: isIPv6),
            remotePort: remotePort,
            state: state
        ))
    }

    /// An `insi_laddr` / `insi_faddr` union as text; nil for the unspecified address. IPv4-mapped
    /// IPv6 addresses (dual-stack sockets) come out as plain IPv4.
    static func endpointAddress(_ union: some Any, isIPv6: Bool) -> String? {
        let bytes: [UInt8] = withUnsafeBytes(of: union) { Array($0.prefix(16)) }
        return endpointAddress(bytes: bytes, isIPv6: isIPv6)
    }

    /// 16 bytes: an IPv6 address, or 12 bytes of padding then an IPv4 address (`in4in6_addr`).
    static func endpointAddress(bytes: [UInt8], isIPv6: Bool) -> String? {
        guard bytes.count >= 16 else {
            return nil
        }
        let mapped = bytes[0 ..< 10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        let isV4 = !isIPv6 || mapped
        let address = isV4 ? Array(bytes[12 ..< 16]) : Array(bytes[0 ..< 16])
        guard address.contains(where: { $0 != 0 }) else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = address.withUnsafeBytes { source -> Bool in
            guard let base = source.baseAddress else {
                return false
            }
            return inet_ntop(isV4 ? AF_INET : AF_INET6, base, &buffer, socklen_t(buffer.count)) != nil
        }
        guard converted else {
            return nil
        }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
