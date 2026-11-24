import Foundation

/// Why the Mac is "under strain" (spec 7.3). The menu bar shows a warning while any holds.
public enum StrainReason: String, Hashable, Sendable, Codable {
    case cpu, memory, disk, thermal

    /// Looked up once: the menu bar reads it every tick.
    public var description: String {
        switch self {
        case .cpu: Self.cpuDescription
        case .memory: Self.memoryDescription
        case .disk: Self.diskDescription
        case .thermal: Self.thermalDescription
        }
    }

    private static let cpuDescription = String(
        localized: "CPU has been above \(Formatters.percent(StrainDetector.cpuThreshold)) for a minute", bundle: .strings,
        comment: "Why the menu bar shows a warning. The argument is a percentage, e.g. 85%."
    )
    private static let memoryDescription = String(localized: "Memory pressure is high", bundle: .strings)
    private static let diskDescription = String(localized: "The startup disk is almost full", bundle: .strings)
    private static let thermalDescription = String(localized: "This Mac is running hot", bundle: .strings)
}

public enum StrainDetector {
    public static let cpuThreshold = 85.0
    public static let cpuWindow: TimeInterval = 60
    public static let diskFreeThreshold = 0.05

    /// The first reason that holds, checked in order CPU, memory, disk, thermal; nil when none.
    ///
    /// - Parameter cpuHistory: recent (time, total CPU %) points, any order.
    public static func evaluate(
        cpuHistory: [(at: Date, percent: Double)],
        now: Date,
        memoryPressure: MemoryPressure,
        bootVolumeFreeFraction: Double?,
        thermal: ThermalPressure
    ) -> StrainReason? {
        let window = cpuHistory.filter { now.timeIntervalSince($0.at) <= cpuWindow }
        // Needs a minute of history (within one 5 s tick) and every point over the line.
        if let oldest = window.map(\.at).min(), now.timeIntervalSince(oldest) >= cpuWindow - 5,
           window.allSatisfy({ $0.percent >= cpuThreshold }) {
            return .cpu
        }
        if memoryPressure != .normal {
            return .memory
        }
        if let free = bootVolumeFreeFraction, free < diskFreeThreshold {
            return .disk
        }
        if thermal >= .serious {
            return .thermal
        }
        return nil
    }
}

/// Holds the menu bar's strain steady (D-121). `StrainDetector` reads each snapshot on its own,
/// so memory pressure hovering at the warning line turned the icon on and off every tick, each
/// time with its bounce. A new reason must hold for `onset`, and strain ends only after `release`
/// without it. CPU needs no onset: `StrainDetector` already asks for a full minute over the line.
public struct StrainSmoother: Sendable {
    public static let onset: TimeInterval = 20
    public static let release: TimeInterval = 60

    public private(set) var shown: StrainReason?
    private var pending: (reason: StrainReason?, since: Date)?

    public init() {}

    static func wait(for candidate: StrainReason?) -> TimeInterval {
        switch candidate {
        case nil: release
        case .cpu: 0
        case .memory, .disk, .thermal: onset
        }
    }

    /// Pure given its state: the strain to show, from this snapshot's reading.
    public mutating func update(_ candidate: StrainReason?, now: Date) -> StrainReason? {
        guard candidate != shown else {
            pending = nil
            return shown
        }
        let wait = Self.wait(for: candidate)
        if wait == 0 {
            shown = candidate
            pending = nil
        } else if let pending, pending.reason == candidate {
            if now.timeIntervalSince(pending.since) >= wait {
                shown = candidate
                self.pending = nil
            }
        } else {
            pending = (candidate, now)
        }
        return shown
    }
}
