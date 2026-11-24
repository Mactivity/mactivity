import Foundation

/// Changes over time, for Checkup (D-160): what uses more than it used to. Pure: the UI reads
/// the averages from History, this decides what's a real change.
public enum Trends {
    /// An app whose average grew between two spans.
    public struct Growth: Hashable, Sendable {
        public let app: AppIdentity
        public let before: Double
        public let now: Double

        public init(app: AppIdentity, before: Double, now: Double) {
            self.app = app
            self.before = before
            self.now = now
        }
    }

    /// Memory that grew by at least half, and by 500 MB or more: steady growth, not noise.
    public static let memoryRatio = 1.5
    public static let memoryIncrease = 500_000_000.0

    /// Apps whose average now is at least `ratio` times their average before, and higher by at
    /// least `increase`. Apps with no figure before are new, not growing, and left out.
    public static func growing(now: [AppTotal], before: [AppTotal], ratio: Double, increase: Double) -> [Growth] {
        let earlier = Dictionary(before.map { ($0.app.id, $0.value) }, uniquingKeysWith: max)
        return now.compactMap { total in
            guard let then = earlier[total.app.id], then > 0, total.value >= then * ratio, total.value - then >= increase else {
                return nil
            }
            return Growth(app: total.app, before: then, now: total.value)
        }
        .sorted { $0.now - $0.before > $1.now - $1.before }
    }

    /// Battery drain while on battery, percent per hour; nil under three hours on battery, too
    /// little to compare.
    public static func drainRate(_ use: BatteryUse) -> Double? {
        guard use.onBatterySeconds >= 3 * 3600 else {
            return nil
        }
        return use.drainedPercent / (use.onBatterySeconds / 3600)
    }

    /// Draining at least a quarter faster, and by at least a point an hour.
    public static func drainsFaster(now: Double, before: Double) -> Bool {
        before > 0 && now >= before * 1.25 && now - before >= 1
    }
}
