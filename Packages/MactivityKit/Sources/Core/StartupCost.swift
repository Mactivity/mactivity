import Foundation

/// How hard the Mac worked right after it last started (D-171): when it settled, and how busy
/// it was until then. The apps behind it come from History's ranking for the same minutes.
public struct StartupCost: Hashable, Sendable, Codable {
    /// When the Mac started (`kern.boottime`). Identifies the startup.
    public let bootedAt: Date
    /// The first minute History recorded after it: Mactivity opens at login, so about when the
    /// person logged in.
    public let loginAt: Date
    /// From login until the processor stayed calm; nil when it was still busy at the end of the window.
    public let settledAfter: TimeInterval?
    /// The whole Mac's average CPU over the window, in percent.
    public let averageCPU: Double

    public init(bootedAt: Date, loginAt: Date, settledAfter: TimeInterval?, averageCPU: Double) {
        self.bootedAt = bootedAt
        self.loginAt = loginAt
        self.settledAfter = settledAfter
        self.averageCPU = averageCPU
    }

    /// The minutes the apps are ranked over.
    public var window: DateInterval {
        DateInterval(start: loginAt, duration: StartupCosts.window)
    }
}

public enum StartupCosts {
    /// The stretch after login that's measured.
    public static let window: TimeInterval = 10 * 60
    /// A minute under this, whole-Mac CPU, is calm.
    public static let calmPercent = 25.0
    /// Settled means this many calm minutes in a row.
    public static let calmMinutes = 2
    /// Recording that starts later than this after startup didn't see the login (Mactivity
    /// wasn't opened at login, or the Mac sat at the login window).
    public static let latestStart: TimeInterval = 30 * 60
    /// Too few minutes recorded to say anything.
    static let fewestMinutes = 4

    /// - Parameters:
    ///   - cpu: the whole Mac's CPU by the minute from startup on, each point at its minute's start.
    ///   - bootedAt: `kern.boottime`.
    public static func measure(cpu: [SeriesPoint], bootedAt: Date) -> StartupCost? {
        let after = cpu.filter { $0.at >= bootedAt }.sorted { $0.at < $1.at }
        guard let first = after.first, first.at.timeIntervalSince(bootedAt) <= latestStart else {
            return nil
        }
        let minutes = after.filter { $0.at < first.at.addingTimeInterval(window) }
        guard minutes.count >= fewestMinutes else {
            return nil
        }
        var settled: TimeInterval?
        var run = 0
        var previous: Date?
        for point in minutes {
            // A missing minute (the Mac slept) breaks a run of calm ones.
            let follows = previous.map { point.at.timeIntervalSince($0) <= 90 } ?? true
            run = point.average < calmPercent ? (follows ? run + 1 : 1) : 0
            previous = point.at
            if run == calmMinutes {
                let start = point.at.addingTimeInterval(-Double(calmMinutes - 1) * 60)
                settled = max(0, start.timeIntervalSince(first.at))
                break
            }
        }
        let average = minutes.reduce(0) { $0 + $1.average } / Double(minutes.count)
        return StartupCost(bootedAt: bootedAt, loginAt: first.at, settledAfter: settled, averageCPU: average)
    }
}
