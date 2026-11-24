import Foundation

/// The words for an unusual day: "4.2 GB of memory, 3× its usual 1.4 GB", on Overview, in
/// Checkup and in the Out of the ordinary alert (D-198, D-201).
public enum UnusualText {
    /// For the on-device model (D-199): plain English, whatever the app's language.
    public static func english(_ usage: UnusualUsage) -> String {
        let what = switch usage.metric {
        case .memory: "memory"
        case .energy: "power"
        default: "processor"
        }
        let today = figure(usage.metric, usage.today)
        guard let ratio = usage.ratio, usage.usual >= Baselines.floor(usage.metric) / 4 else {
            return "\(what) \(today), usually next to nothing"
        }
        return "\(what) \(today), \(Int(ratio.rounded()))× its usual \(figure(usage.metric, usage.usual))"
    }

    public static func figure(_ metric: Metric, _ value: Double) -> String {
        switch metric {
        case .memory: Formatters.memory(UInt64(max(0, value)))
        case .energy: Formatters.power(milliwatts: value)
        default: Formatters.percent(value)
        }
    }

    public static func detail(_ usage: UnusualUsage) -> String {
        let today = figure(usage.metric, usage.today)
        // A usual that's next to nothing reads as "usually idle", not "422× its usual 0.02%".
        guard let ratio = usage.ratio, usage.usual >= Baselines.floor(usage.metric) / 4 else {
            switch usage.metric {
            case .memory:
                return String(localized: "\(today) of memory today; it usually holds very little", bundle: .strings)
            case .energy:
                return String(localized: "\(today) of power today; it usually draws very little", bundle: .strings)
            default:
                return String(localized: "\(today) of the processor today; it's usually idle", bundle: .strings)
            }
        }
        let times = Int(ratio.rounded()).formatted()
        let usual = figure(usage.metric, usage.usual)
        switch usage.metric {
        case .memory:
            return String(localized: "\(today) of memory today, \(times)× its usual \(usual)", bundle: .strings)
        case .energy:
            return String(localized: "\(today) of power today, \(times)× its usual \(usual)", bundle: .strings)
        default:
            return String(localized: "\(today) of the processor today, \(times)× its usual \(usual)", bundle: .strings)
        }
    }
}
