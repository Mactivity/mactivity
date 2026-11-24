import Foundation

// Unlocks and failed attempts (D-288), from the unified log's lines at the moment of an unlock.
// Undocumented, so this may stop working with any macOS: what it can't read, it says so.

public enum UnlockMethod: String, Hashable, Sendable, CaseIterable {
    case touchID, password, appleWatch
    /// Unlocked, but the log's lines around it didn't say how.
    case unknown
}

public struct UnlockEvent: Hashable, Sendable, Identifiable {
    public let at: Date
    public let method: UnlockMethod

    public var id: Date {
        at
    }

    public init(at: Date, method: UnlockMethod) {
        self.at = at
        self.method = method
    }
}

public struct FailedUnlock: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case password
        /// A finger Touch ID didn't recognize.
        case touchID
        /// macOS logged a failure and didn't say of what.
        case other
    }

    public let at: Date
    public let kind: Kind

    public var id: Date {
        at
    }

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

public struct UnlockLogReading: Hashable, Sendable {
    /// Newest first.
    public let unlocks: [UnlockEvent]
    /// Newest first. Empty doesn't mean there were none (D-288).
    public let failures: [FailedUnlock]
    /// The earliest related line found: how far back this actually reaches.
    public let coveredFrom: Date?

    public init(unlocks: [UnlockEvent], failures: [FailedUnlock], coveredFrom: Date?) {
        self.unlocks = unlocks
        self.failures = failures
        self.coveredFrom = coveredFrom
    }

    /// Pure: how many unlocks each way, most first.
    public var byMethod: [(method: UnlockMethod, count: Int)] {
        let counts = Dictionary(grouping: unlocks, by: \.method).mapValues(\.count)
        return UnlockMethod.allCases
            .compactMap { method in counts[method].map { (method: method, count: $0) } }
            .sorted { $0.count > $1.count }
    }
}

public enum UnlockReading: Hashable, Sendable {
    /// The log couldn't be read, or its lines no longer add up.
    case unreadable
    case read(UnlockLogReading)
}

/// Where unlocks come from (D-288): macOS's log, or Simulated.
public protocol UnlockHistorySource: Sendable {
    /// Slow: a read of the log takes several seconds, so call it only while its card shows.
    func read(now: Date) async -> UnlockReading
}
