import Core
import Darwin
import Foundation
import SystemConfiguration

/// System-wide throughput from the 64-bit interface counters in `sysctl NET_RT_IFLIST2`, and the
/// primary interface from the SystemConfiguration dynamic store (spec 6.5). Public API only.
///
/// `getifaddrs` would be simpler, but its `if_data` counters are 32-bit and wrap every 4 GB.
public actor NetworkSampler: NetworkSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private let clock = SuspendingClock()
    private let store: SCDynamicStore?
    private let primaryKeys: [CFString]
    /// Reused between calls; grown when the kernel says it's too small.
    private var buffer: [UInt8] = []
    private var previous: (counters: [String: InterfaceCounters], at: SuspendingClock.Instant)?
    /// The primary interface is an XPC round trip to configd, so it's read again only when
    /// configd posts a network change, or after `primaryInterfaceMaxAge` (D-086).
    private let networkChange = NotifyWatch("com.apple.system.config.network_change")
    private var primary: (name: String?, readAt: SuspendingClock.Instant)?
    static let primaryInterfaceMaxAge: Duration = .seconds(30)

    public init() {
        store = SCDynamicStoreCreate(nil, "app.mactivity.network" as CFString, nil, nil)
        primaryKeys = [kSCEntNetIPv4, kSCEntNetIPv6].map {
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, $0)
        }
    }

    public func sample() async throws -> NetworkStats {
        let now = clock.now
        let counters = try readCounters()
        let elapsed = previous.map { (now - $0.at).seconds } ?? 0
        let rates = NetworkMath.throughput(previous: previous?.counters, current: counters, elapsedSeconds: elapsed)
        previous = (counters, now)
        return NetworkStats(inBPS: rates.inBPS, outBPS: rates.outBPS, primaryInterface: cachedPrimaryInterface(now: now))
    }

    private func cachedPrimaryInterface(now: SuspendingClock.Instant) -> String? {
        let posted = networkChange.posted()
        if let primary, !NotifyWatch.needsRead(posted: posted, lastRead: primary.readAt, now: now, maxAge: Self.primaryInterfaceMaxAge) {
            return primary.name
        }
        let name = primaryInterface()
        primary = (name, now)
        return name
    }

    /// `State:/Network/Global/IPv4` → `PrimaryInterface`, then the IPv6 entity for IPv6-only
    /// networks. Nil when the Mac is offline.
    private func primaryInterface() -> String? {
        guard let store else {
            return nil
        }
        for key in primaryKeys {
            if let global = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let name = global[kSCDynamicStorePropNetPrimaryInterface as String] as? String {
                return name
            }
        }
        return nil
    }

    // MARK: Counters

    /// Byte counters for every interface, counted or not; `NetworkMath` does the filtering.
    private func readCounters() throws -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Try the buffer we have; only ask for the size when it's missing or too small (ENOMEM).
        // Three rounds covers interfaces coming up between the size query and the read.
        for _ in 0 ..< 3 {
            var size = buffer.count
            if !buffer.isEmpty {
                if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 {
                    return buffer.withUnsafeBytes { Self.parse(UnsafeRawBufferPointer(rebasing: $0.prefix(size))) }
                }
                guard errno == ENOMEM else {
                    throw SamplingError.sysctl(name: "NET_RT_IFLIST2", errno: errno)
                }
            }
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0 else {
                throw SamplingError.sysctl(name: "NET_RT_IFLIST2", errno: errno)
            }
            // Headroom for an interface or two coming up before the next read.
            buffer = [UInt8](repeating: 0, count: needed + needed / 4 + 1024)
        }
        throw SamplingError.sysctl(name: "NET_RT_IFLIST2", errno: ENOMEM)
    }

    /// Walks the routing messages, keeping each `RTM_IFINFO2` interface's name and `if_data64` bytes.
    private static func parse(_ raw: UnsafeRawBufferPointer) -> [String: InterfaceCounters] {
        var counters: [String: InterfaceCounters] = [:]
        let headerSize = MemoryLayout<if_msghdr2>.size
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= raw.count {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let length = Int(header.ifm_msglen)
            guard length > 0, offset + length <= raw.count else {
                break
            }
            if Int32(header.ifm_type) == RTM_IFINFO2, length >= headerSize {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let link = UnsafeRawBufferPointer(rebasing: raw[(offset + headerSize) ..< (offset + length)])
                if let name = linkName(link, addresses: message.ifm_addrs) ?? indexName(message.ifm_index) {
                    counters[name] = InterfaceCounters(
                        bytesIn: message.ifm_data.ifi_ibytes,
                        bytesOut: message.ifm_data.ifi_obytes
                    )
                }
            }
            offset += length
        }
        return counters
    }

    /// The BSD name from the `sockaddr_dl` that follows an `if_msghdr2` when `RTA_IFP` is set.
    private static func linkName(_ link: UnsafeRawBufferPointer, addresses: Int32) -> String? {
        guard addresses & RTA_IFP != 0,
              link.count >= MemoryLayout<sockaddr_dl>.size,
              let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)
        else {
            return nil
        }
        let address = link.loadUnaligned(as: sockaddr_dl.self)
        let nameLength = Int(address.sdl_nlen)
        guard Int32(address.sdl_family) == AF_LINK, nameLength > 0, dataOffset + nameLength <= link.count else {
            return nil
        }
        return String(bytes: link[dataOffset ..< (dataOffset + nameLength)], encoding: .utf8)
    }

    private static func indexName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else {
            return nil
        }
        return String(bytes: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
