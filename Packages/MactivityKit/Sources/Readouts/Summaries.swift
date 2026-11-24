import Core
import Foundation

/// One-sentence, speakable summaries for Siri and Shortcuts results (E6). Pure, so the exact
/// wording is tested; every figure goes through `Formatters`.
public enum Summaries {
    /// "CPU is at 23%. 18 GB of 48 GB memory used. Battery at 87%, charging."
    public static func system(_ system: SystemSample, locale: Locale = .current) -> String {
        let cpu = Formatters.percent(system.cpu.totalPercent, locale: locale)
        let used = Formatters.memory(system.memory.usedBytes, locale: locale)
        let total = Formatters.memory(system.memory.totalBytes, locale: locale)
        var sentences = [
            String(localized: "CPU is at \(cpu).", bundle: .strings, locale: locale, comment: "Siri summary. The argument is a percent."),
            String(
                localized: "\(used) of \(total) memory used.", bundle: .strings, locale: locale,
                comment: "Siri summary: memory in use, then the Mac's total memory, e.g. 18 GB of 48 GB."
            ),
        ]
        switch system.memory.pressure {
        case .normal:
            break
        case .warning:
            sentences.append(String(
                localized: "Memory pressure is elevated.", bundle: .strings, locale: locale,
                comment: "Siri summary: macOS reports memory pressure at its warning level."
            ))
        case .critical:
            sentences.append(String(
                localized: "Memory pressure is critical.", bundle: .strings, locale: locale,
                comment: "Siri summary: macOS reports memory pressure at its critical level."
            ))
        }
        if let battery = system.battery {
            sentences.append(batterySentence(battery, locale: locale))
        }
        if system.thermal >= .serious {
            sentences.append(String(localized: "Your Mac is running hot.", bundle: .strings, locale: locale, comment: "Siri summary."))
        }
        return sentences.joined(separator: " ")
    }

    /// "Battery at 87%, charging." / "Battery at 40%, 2h 5m left."
    static func batterySentence(_ battery: BatteryStats, locale: Locale) -> String {
        let percent = Formatters.percent(battery.percent, locale: locale)
        if battery.isCharging {
            return String(localized: "Battery at \(percent), charging.", bundle: .strings, locale: locale, comment: "Siri summary.")
        }
        if battery.source == .ac {
            return String(
                localized: "Battery at \(percent), on power.", bundle: .strings, locale: locale,
                comment: "Siri summary: on the power adapter, not charging."
            )
        }
        if let remaining = battery.timeRemaining {
            let left = Formatters.duration(remaining)
            return String(
                localized: "Battery at \(percent), \(left) left.", bundle: .strings, locale: locale,
                comment: "Siri summary: battery percent, then time left, e.g. 2h 5m."
            )
        }
        return String(localized: "Battery at \(percent).", bundle: .strings, locale: locale, comment: "Siri summary.")
    }

    /// "Top apps by memory: Xcode 6.2 GB, Safari 3.1 GB, and Slack 812 MB."
    public static func topApps(_ apps: [AppAggregate], by ranking: AppRanking, locale: Locale = .current) -> String {
        guard !apps.isEmpty else {
            return String(localized: "No apps to rank right now.", bundle: .strings, locale: locale, comment: "Siri summary.")
        }
        let items = apps.map { app in
            let name = app.app.name
            let figure = ranking.formatted(app, locale: locale)
            return String(
                localized: "\(name) \(figure)", bundle: .strings, locale: locale,
                comment: "One app in a spoken list: its name, then its figure, e.g. Xcode 6.2 GB."
            )
        }
        let list = items.formatted(.list(type: .and).locale(locale))
        return switch ranking {
        case .cpu:
            String(localized: "Top apps by CPU: \(list).", bundle: .strings, locale: locale, comment: "Siri summary; a list of apps.")
        case .memory:
            String(localized: "Top apps by memory: \(list).", bundle: .strings, locale: locale, comment: "Siri summary; a list of apps.")
        case .energy:
            String(localized: "Top apps by energy: \(list).", bundle: .strings, locale: locale, comment: "Siri summary; a list of apps.")
        case .disk:
            String(localized: "Top apps by disk: \(list).", bundle: .strings, locale: locale, comment: "Siri summary; a list of apps.")
        case .network:
            String(localized: "Top apps by network: \(list).", bundle: .strings, locale: locale, comment: "Siri summary; a list of apps.")
        }
    }

    /// "3 dev servers in 2 projects. storefront-web: port 4321, idle 2h. api: ports 8080 and 8081, working."
    public static func devServers(_ projects: [Project], locale: Locale = .current) -> String {
        let servers = projects.flatMap(\.servers)
        guard !servers.isEmpty else {
            return String(localized: "No dev servers are running.", bundle: .strings, locale: locale, comment: "Siri summary.")
        }
        let head = String(
            localized: "\(servers.count) dev servers in \(projects.count) projects.", bundle: .strings, locale: locale,
            comment: "Siri summary: how many dev servers are running, and in how many projects."
        )
        let details = projects.map { project in
            projectSentence(project.name, ports: ports(project.ports, locale: locale), activity: project.activity, locale: locale)
        }
        return ([head] + details).joined(separator: " ")
    }

    /// "api: ports 8080 and 8081, idle 2h 5m."
    private static func projectSentence(_ name: String, ports: String, activity: ProjectActivity, locale: Locale) -> String {
        switch activity {
        case .working:
            return String(
                localized: "\(name): \(ports), working.", bundle: .strings, locale: locale,
                comment: "Siri summary: a project, its ports (e.g. port 4321), and that it used CPU recently."
            )
        case let .idle(minutes):
            let idle = Formatters.duration(.seconds(minutes * 60))
            return String(
                localized: "\(name): \(ports), idle \(idle).", bundle: .strings, locale: locale,
                comment: "Siri summary: a project, its ports (e.g. port 4321), and how long it's been idle (e.g. 2h 5m)."
            )
        case .barelyUsed:
            return String(
                localized: "\(name): \(ports), barely used.", bundle: .strings, locale: locale,
                comment: "Siri summary: a project, its ports (e.g. port 4321), and that it's up a day with almost no CPU time."
            )
        }
    }

    /// "Nothing's idle." / "2 idle dev servers: web (port 4321) and docs (port 3000)."
    public static func idleServers(_ projects: [Project], locale: Locale = .current) -> String {
        let idle = projects.flatMap { project in project.servers.filter(\.activity.isIdle).map { (project.name, $0) } }
        guard !idle.isEmpty else {
            return String(localized: "No dev servers are idle.", bundle: .strings, locale: locale, comment: "Siri summary.")
        }
        let items = idle.map { name, server in
            let ports = ports(server.ports, locale: locale)
            return String(
                localized: "\(name) (\(ports))", bundle: .strings, locale: locale,
                comment: "One project in a spoken list: its name, then its ports, e.g. web (port 4321)."
            )
        }
        let list = items.formatted(.list(type: .and).locale(locale))
        return String(
            localized: "\(idle.count) idle dev servers: \(list).", bundle: .strings, locale: locale,
            comment: "Siri summary: the number of idle dev servers, then a list of them."
        )
    }

    /// "port 4321", "ports 8080 and 8081", "no ports".
    public static func ports(_ ports: [UInt16], locale: Locale = .current) -> String {
        switch ports.count {
        case 0:
            return String(localized: "no ports", bundle: .strings, locale: locale, comment: "A dev server listening on no TCP ports.")
        case 1:
            let port = String(ports[0])
            return String(localized: "port \(port)", bundle: .strings, locale: locale, comment: "A dev server's one TCP port (port 4321).")
        default:
            let list = ports.map { String($0) }.formatted(.list(type: .and).locale(locale))
            return String(
                localized: "ports \(list)", bundle: .strings, locale: locale,
                comment: "A dev server's TCP ports, e.g. ports 8080 and 8081."
            )
        }
    }
}
