import Foundation

extension Checkup {
    /// Slower than this to settle after login is worth a look (D-171).
    static let slowStartup: TimeInterval = 5 * 60

    /// A login that kept the Mac busy for minutes, with the apps behind it (D-171).
    static func slowStartup(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let cost = inputs.lastStartup, (cost.settledAfter ?? .infinity) >= slowStartup else {
            return []
        }
        let title = if let settled = cost.settledAfter {
            String(
                localized: "Your Mac took \(Formatters.duration(.seconds(settled))) to settle after logging in",
                bundle: .strings,
                comment: "Checkup: how long the processor stayed busy after the last login, e.g. 8m"
            )
        } else {
            String(localized: "Your Mac was still busy 10 minutes after logging in", bundle: .strings, comment: "Checkup: the last login")
        }
        let detail = if inputs.lastStartupApps.isEmpty {
            String(localized: "Startup shows what opens with your Mac.", bundle: .strings)
        } else {
            String(
                localized: "Busiest then: \(inputs.lastStartupApps.formatted(.list(type: .and))). Startup shows what opens with your Mac.",
                bundle: .strings,
                comment: "Checkup: the apps busiest after login, e.g. Dropbox and Adobe Creative Cloud"
            )
        }
        return [CheckupItem(id: "slow-startup", area: .startup, severity: .suggestion, title: title, detail: detail)]
    }
}
