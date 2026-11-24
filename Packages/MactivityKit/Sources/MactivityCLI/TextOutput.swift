import Core
import Foundation
import Readouts

/// Human-readable output. Every figure goes through `Formatters`, so the CLI reads like the app.
enum TextOutput {
    static let nameWidth = 32

    static func top(_ snapshot: Snapshot, options: Command.TopOptions, locale: Locale = .current) -> String {
        let apps = options.ranking.rank(snapshot.apps, limit: options.limit)
        var table = TextTable([
            .init(title: "APP", alignment: .left),
            .init(title: "PROCS", alignment: .right),
            .init(title: "CPU", alignment: .right),
            .init(title: "MEMORY", alignment: .right),
            .init(title: "ENERGY", alignment: .right),
            .init(title: "DISK", alignment: .right),
            .init(title: "NETWORK", alignment: .right),
        ])
        for app in apps {
            table.add([
                TextTable.truncate(app.app.name, to: nameWidth),
                "\(app.processCount)",
                AppRanking.cpu.formatted(app, locale: locale),
                AppRanking.memory.formatted(app, locale: locale),
                AppRanking.energy.formatted(app, locale: locale),
                AppRanking.disk.formatted(app, locale: locale),
                AppRanking.network.formatted(app, locale: locale),
            ])
        }
        return table.render()
    }

    static func system(_ system: SystemSample, locale: Locale = .current) -> String {
        var table = TextTable([.init(title: "", alignment: .left), .init(title: "", alignment: .left)])
        let cpu = system.cpu
        table.add([
            "CPU",
            "\(Formatters.percent(cpu.totalPercent, locale: locale)) (user \(Formatters.percent(cpu.userPercent, locale: locale)), "
                + "system \(Formatters.percent(cpu.systemPercent, locale: locale)))",
        ])
        for cluster in cpu.clusters.sorted(by: { $0.level < $1.level }) {
            let cores = cluster.coreIndexes.count == 1 ? "1 core" : "\(cluster.coreIndexes.count) cores"
            table.add(["  \(cluster.name)", "\(Formatters.percent(cluster.percent, locale: locale)) (\(cores))"])
        }
        table.add(["  Load", Formatters.loadAverage(cpu.loadAverage, locale: locale)])

        let memory = system.memory
        table.add([
            "Memory",
            "\(Formatters.memory(memory.usedBytes, locale: locale)) of \(Formatters.memory(memory.totalBytes, locale: locale)) used "
                + "(pressure \(memory.pressure.rawValue), swap \(Formatters.memory(memory.swapUsedBytes, locale: locale)))",
        ])

        let disk = system.disk
        for (index, volume) in disk.volumes.enumerated() {
            table.add([
                index == 0 ? "Disk" : "",
                "\(volume.name): \(Formatters.bytes(volume.freeBytes, locale: locale)) free of "
                    + Formatters.bytes(volume.totalBytes, locale: locale),
            ])
        }
        table.add([
            disk.volumes.isEmpty ? "Disk" : "",
            "read \(Formatters.rate(disk.readBPS, locale: locale)), write \(Formatters.rate(disk.writeBPS, locale: locale))",
        ])

        let network = system.network
        let interface = network.primaryInterface.map { " (\($0))" } ?? ""
        table.add([
            "Network",
            "in \(Formatters.rate(network.inBPS, locale: locale)), out \(Formatters.rate(network.outBPS, locale: locale))\(interface)",
        ])
        table.add([
            "GPU",
            system.gpu.map { "\($0.name): \(Formatters.percent($0.utilizationPercent, locale: locale))" } ?? "not readable",
        ])
        table.add(["Battery", system.battery.map { battery($0, locale: locale) } ?? "none"])
        table.add(["Thermal", system.thermal.rawValue])
        table.add(["Uptime", Formatters.duration(system.uptime)])
        return table.render(header: false)
    }

    static func battery(_ battery: BatteryStats, locale: Locale) -> String {
        var parts = [Formatters.percent(battery.percent, locale: locale)]
        if battery.isCharging {
            parts.append("charging")
        } else if battery.source == .ac {
            parts.append("on power")
        } else {
            parts.append("on battery")
        }
        if let remaining = battery.timeRemaining {
            parts.append("\(Formatters.duration(remaining)) \(battery.source == .ac ? "to full" : "left")")
        }
        if let cycles = battery.cycleCount {
            parts.append("\(cycles) cycles")
        }
        return parts.joined(separator: ", ")
    }

    static func projects(_ projects: [Project], now: Date, home: String, locale: Locale = .current) -> String {
        guard !projects.isEmpty else {
            return "No dev servers are running."
        }
        var table = TextTable([
            .init(title: "PROJECT", alignment: .left),
            .init(title: "PID", alignment: .right),
            .init(title: "SERVER", alignment: .left),
            .init(title: "PORTS", alignment: .left),
            .init(title: "RUNTIME", alignment: .left),
            .init(title: "MEMORY", alignment: .right),
            .init(title: "UP", alignment: .right),
            .init(title: "ACTIVITY", alignment: .left),
            .init(title: "PATH", alignment: .left),
        ])
        for project in projects {
            for (index, server) in project.servers.enumerated() {
                table.add([
                    index == 0 ? TextTable.truncate(project.name, to: 24) : "",
                    "\(server.pid)",
                    TextTable.truncate(server.name, to: 16),
                    server.ports.map { String($0) }.joined(separator: ","),
                    server.runtime.title,
                    Formatters.memory(server.memoryBytes, locale: locale),
                    Formatters.duration(.seconds(max(0, now.timeIntervalSince(server.startedAt)))),
                    server.activity.title,
                    index == 0 ? Formatters.displayPath(project.rootPath, home: home) : "",
                ])
            }
        }
        return table.render()
    }
}
