import Foundation

/// What Ask Mactivity (D-153) tells the on-device model about the Mac before the question: the
/// figures now, the busiest apps, and the slowdown diagnosis. Short, since the model's context is
/// a few thousand tokens and the history tool's answers need room too. Pure.
public enum AskContext {
    public static let appsListed = 6

    public static func describe(_ snapshot: Snapshot?, causes: [SlowdownCause], now: Date) -> String {
        var lines = ["Time now: \(now.formatted(date: .abbreviated, time: .shortened))."]
        guard let snapshot else {
            lines.append("No figures yet: Mactivity has just started.")
            return lines.joined(separator: "\n")
        }
        let system = snapshot.system
        let cores = system.cpu.perCorePercent.count
        lines.append(
            "CPU: \(Formatters.percent(system.cpu.totalPercent)) of the whole Mac (\(cores) cores), "
                + "load average \(system.cpu.loadAverage.one.formatted(.number.precision(.fractionLength(1))))."
        )
        let memory = system.memory
        lines.append(
            "Memory: \(Formatters.memory(memory.usedBytes)) used of \(Formatters.memory(memory.totalBytes)), "
                + "memory pressure \(memory.pressure.rawValue), swap \(Formatters.memory(memory.swapUsedBytes))."
        )
        if let boot = system.disk.bootVolume {
            lines.append(
                "Startup disk: \(Formatters.bytes(boot.freeBytes)) free of \(Formatters.bytes(boot.totalBytes)); "
                    + "reading \(Formatters.rate(system.disk.readBPS)), writing \(Formatters.rate(system.disk.writeBPS))."
            )
        }
        lines.append("Network: receiving \(Formatters.rate(system.network.inBPS)), sending \(Formatters.rate(system.network.outBPS)).")
        if let gpu = system.gpu {
            lines.append("GPU: \(Formatters.percent(gpu.utilizationPercent)).")
        }
        if let battery = system.battery {
            let state = battery.source == .battery ? "on battery" : (battery.isCharging ? "charging" : "plugged in")
            let left = battery.timeRemaining.map { ", about \(Formatters.duration($0)) left" } ?? ""
            lines.append("Battery: \(Formatters.percent(battery.percent)), \(state)\(left).")
        }
        var heat = "Thermal pressure: \(system.thermal.rawValue)"
        if let cpu = system.sensors?.temperature(id: "cpu") {
            // Celsius, spelled out: the model shouldn't guess the scale.
            heat += ", CPU \(Int(cpu.rounded())) °C"
        }
        lines.append(heat + ".")
        let apps = snapshot.apps
        let byCPU = AppAggregate.ranked(apps) { $0.cpuPercent }.prefix(appsListed)
        lines.append("Busiest apps by CPU: " + byCPU.map { "\($0.app.name) \(Formatters.percent($0.cpuPercent, fractionDigits: 1))" }
            .joined(separator: ", ") + ".")
        let byMemory = AppAggregate.ranked(apps) { Double($0.memoryBytes) }.prefix(appsListed)
        lines.append("Largest apps by memory: " + byMemory.map { "\($0.app.name) \(Formatters.memory($0.memoryBytes))" }
            .joined(separator: ", ") + ".")
        if causes.isEmpty {
            lines.append("Slowdown check: nothing stands out.")
        } else {
            lines.append("Slowdown check, worst first:")
            lines += causes.prefix(4).map { "- \($0.title). \($0.detail)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Could be a question: a question mark, a question word first, or three words or more.
    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumLength(trimmed) else {
            return false
        }
        return isPlainQuestion(trimmed) || trimmed.split(separator: " ").count >= 3
    }

    /// Surely a question: a question mark, or a question word first. Three words alone could be
    /// an app's name ("Visual Studio Code"), so those offer Ask after the matches instead.
    public static func isPlainQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // "?", and the full-width "？" of Japanese and Chinese input (D-221).
        if trimmed.count >= minimumLength(trimmed), trimmed.hasSuffix("?") || trimmed.hasSuffix("？") || trimmed.hasPrefix("¿") {
            return true
        }
        let words = QuickSearch.fold(trimmed).split(separator: " ")
        return words.count >= 2 && words.first.map { starters.contains(String($0)) } == true
    }

    /// Question words, folded, in the languages Mactivity speaks: Quick Search offers Ask for a
    /// question typed in any of them (D-221).
    static let starters: Set<String> = [
        "what", "why", "which", "how", "is", "are", "does", "did", "who", "when", "should", "can", "whats", "what's",
        "warum", "was", "wie", "welche", "welcher", "welches", "wer", "wann", "ist", "sind", "hat", "kann", "soll",
        "pourquoi", "quel", "quelle", "quels", "quelles", "comment", "qui", "quand", "est-ce",
        "por", "que", "cual", "cuales", "como", "quien", "cuando",
        "perche", "quale", "quali", "come", "cosa", "chi", "quando",
        "waarom", "wat", "welke", "hoe", "wanneer",
        "porque", "qual", "quais", "quem", "quanto",
    ]

    /// Six characters for a question in letters; three in Chinese, Japanese or Korean, where a
    /// word is a character or two ("なぜ遅い？").
    static func minimumLength(_ text: String) -> Int {
        text.unicodeScalars
            .contains { $0.properties.isIdeographic || (0x3040 ... 0x30FF).contains($0.value) || (0xAC00 ... 0xD7AF).contains($0.value) } ?
            3 : 6
    }
}
