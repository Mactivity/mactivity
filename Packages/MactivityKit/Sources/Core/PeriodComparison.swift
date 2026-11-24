import Foundation

/// How one app's figure moved against the previous period of the same length (expansion E3).
public enum PeriodChange: Hashable, Sendable {
    /// Not in the previous period's ranking.
    case new
    /// Relative change: 0.25 is 25% more than the previous period.
    case relative(Double)

    /// "New", "+25%", "−10%", or "Same" inside ±1%.
    public var label: String {
        switch self {
        case .new:
            return String(localized: "New", bundle: .strings, comment: "An app not in the previous period's ranking.")
        case let .relative(fraction):
            let percent = (fraction * 100).rounded()
            if abs(percent) < 1 {
                return String(localized: "Same", bundle: .strings, comment: "An app's use unchanged from the previous period.")
            }
            // The sign is data; the percent takes the locale's style ("25 %" in German).
            return percent > 0 ? "+" + Formatters.percent(percent) : "−" + Formatters.percent(-percent)
        }
    }

    /// True when the app is using more than before (new counts as more).
    public var isIncrease: Bool {
        switch self {
        case .new: true
        case let .relative(fraction): fraction >= 0.01
        }
    }

    /// Each current app's change against the previous period. Empty when the previous period has
    /// no data at all, so the UI can say there isn't enough history rather than mark everything new.
    public static func changes(current: [AppTotal], previous: [AppTotal]) -> [AppIdentity.ID: PeriodChange] {
        guard !previous.isEmpty else {
            return [:]
        }
        let before = Dictionary(previous.map { ($0.app.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        var result: [AppIdentity.ID: PeriodChange] = [:]
        for total in current {
            if let old = before[total.app.id], old > 0 {
                result[total.app.id] = .relative((total.value - old) / old)
            } else {
                result[total.app.id] = .new
            }
        }
        return result
    }
}
