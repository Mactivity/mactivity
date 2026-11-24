import Core
import SwiftUI

/// The whole Mac's watts beside the Battery tab's charge line, and what each caption's unit
/// means on hover (D-258).
extension HistoryStrip {
    /// Energy Impact has no unit, so the strip says what it is.
    static let energyImpactHelp = String(
        localized: """
        Energy Impact is macOS's measure of how much power an app draws, the same score Activity Monitor shows. \
        It has no unit: higher means more battery drain.
        """,
        bundle: .strings
    )

    /// "Average 8.2 W · peak 31 W", or "Since Oct 30: average…" when recording began in the range.
    static func powerCaption(_ power: PowerSummary, range: HistoryRange) -> String {
        let average = Formatters.power(milliwatts: power.averageMW)
        let peak = Formatters.power(milliwatts: power.peakMW)
        guard let since = power.since else {
            return String(
                localized: "Average \(average) · peak \(peak)",
                bundle: .strings,
                comment: "Battery history: the whole Mac's power over the range, e.g. Average 8.2 W · peak 31 W"
            )
        }
        let start = since.formatted(date: range.isWithinDay ? .omitted : .abbreviated, time: .shortened)
        return String(
            localized: "Since \(start): average \(average) · peak \(peak)",
            bundle: .strings,
            comment: "Battery history power, when recording began inside the range"
        )
    }

    /// What the caption's unit means, on hover: Energy Impact's score, bytes against bits, watts.
    static func captionHelp(_ metric: Metric?) -> String {
        switch metric {
        case .energyImpact: energyImpactHelp
        case .netIn, .netOut: FigureHelp.networkRate
        case .diskRead, .diskWrite: FigureHelp.diskRate
        case .energy: FigureHelp.appsPower
        case .powerDraw: FigureHelp.powerDraw
        default: ""
        }
    }

    static let powerHelp = String(
        localized: """
        What your whole Mac drew over this range, display included, in watts (W): the average, and the highest reading. \
        Plugged in, it comes from the charger; otherwise from the battery.
        """,
        bundle: .strings
    )
}
