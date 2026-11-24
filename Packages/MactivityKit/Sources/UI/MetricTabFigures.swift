import Core
import Foundation

/// The headline figure, its caption, and the Overview row, as the figure choices ask (Settings →
/// General → Figures). Automatic is each place's usual figure.
extension MetricTab {
    /// The big figure and the number behind it (which way its digits roll). `choices` picks what
    /// Memory, Disk, Network, and Battery show; Automatic is the usual figure.
    public func headline(_ snapshot: Snapshot, choices: FigureChoices = .automatic) -> (figure: String, value: Double) {
        let system = snapshot.system
        switch self {
        case .cpu:
            return (Formatters.percent(system.cpu.totalPercent), system.cpu.totalPercent)
        case .memory:
            let memory = system.memory
            let percent = memory.usedFraction * 100
            switch choices.memory {
            case .automatic, .used: return (Formatters.memory(memory.usedBytes), Double(memory.usedBytes))
            case .percent: return (Formatters.percent(percent), percent)
            case .pressure: return (memory.status.title, percent)
            }
        case .disk:
            let disk = system.disk
            switch choices.disk {
            case .automatic, .free:
                let free = disk.bootVolume?.freeBytes ?? 0
                return (Formatters.bytes(free), Double(free))
            case .percentUsed:
                let used = disk.bootVolume.map { (1 - $0.freeFraction) * 100 }
                return (used.map { Formatters.percent($0) } ?? "–", used ?? 0)
            case .activity:
                return (Formatters.rate(disk.readBPS), disk.readBPS)
            }
        case .network:
            let network = system.network
            switch choices.network {
            case .automatic, .both: return (Formatters.rate(network.inBPS), network.inBPS)
            case .download: return (Formatters.download(network.inBPS), network.inBPS)
            case .upload: return (Formatters.upload(network.outBPS), network.outBPS)
            }
        case .gpu:
            let value = system.gpu?.utilizationPercent
            return (value.map { Formatters.percent($0) } ?? "–", value ?? 0)
        case .battery:
            guard let battery = system.battery else {
                // The Battery tab's headline on a Mac without a battery: every app's power together.
                let power = snapshot.totalEnergyMW ?? 0
                return (Formatters.power(milliwatts: power), power)
            }
            switch choices.battery {
            case .automatic, .percent, .percentAndTime:
                return (Formatters.percent(battery.percent), battery.percent)
            case .timeLeft:
                let seconds = battery.timeRemaining.map { Double($0.components.seconds) } ?? 0
                return (Formatters.batteryTime(battery), seconds)
            case .power:
                return (Formatters.batteryPower(battery), battery.powerDrawWatts ?? 0)
            }
        }
    }

    /// The line under the headline figure: what the figure is, and what it leaves out.
    public func caption(_ snapshot: Snapshot, choices: FigureChoices = .automatic) -> String {
        let system = snapshot.system
        switch self {
        case .cpu:
            return String(localized: "\(system.cpu.perCorePercent.count) cores", bundle: .strings, comment: "CPU caption: core count")
        case .memory:
            return Self.memoryCaption(system.memory, choice: choices.memory)
        case .disk:
            return Self.diskCaption(system.disk, choice: choices.disk)
        case .network:
            return Self.networkCaption(system.network, choice: choices.network)
        case .gpu:
            return system.gpu?.name ?? String(localized: "No GPU statistics", bundle: .strings)
        case .battery:
            return Self.batteryCaption(system.battery, choice: choices.battery)
        }
    }

    private static func memoryCaption(_ memory: MemoryStats, choice: MemoryFigure) -> String {
        let used = Formatters.memory(memory.usedBytes)
        let total = Formatters.memory(memory.totalBytes)
        switch choice {
        case .automatic, .used:
            return String(localized: "used of \(total)", bundle: .strings, comment: "Memory caption under the used figure")
        case .percent:
            return String(localized: "\(used) of \(total)", bundle: .strings, comment: "Used memory of total memory, e.g. 18 GB of 48 GB")
        case .pressure:
            return String(
                localized: "pressure · \(used) of \(total) used",
                bundle: .strings,
                comment: "Memory caption under the pressure figure: used and total memory"
            )
        }
    }

    private static func diskCaption(_ disk: DiskStats, choice: DiskFigure) -> String {
        let name = disk.bootVolume?.name ?? String(localized: "startup disk", bundle: .strings, comment: "Disk caption, no volume name")
        switch choice {
        case .automatic, .free:
            return String(localized: "free on \(name)", bundle: .strings, comment: "Disk caption under the free figure: volume name")
        case .percentUsed:
            let free = Formatters.bytes(disk.bootVolume?.freeBytes ?? 0)
            return String(
                localized: "used · \(free) free on \(name)",
                bundle: .strings,
                comment: "Disk caption under the percent used figure: free space, volume name"
            )
        case .activity:
            return String(
                localized: "read · \(Formatters.rate(disk.writeBPS)) write",
                bundle: .strings,
                comment: "Disk caption under the read rate figure: write rate"
            )
        }
    }

    private static func networkCaption(_ network: NetworkStats, choice: NetworkFigure) -> String {
        switch choice {
        case .automatic, .both:
            String(
                localized: "down · \(Formatters.rate(network.outBPS)) up",
                bundle: .strings,
                comment: "Network caption under the download figure (“down” names it), then the upload rate: down · 12 kB/s up"
            )
        case .download:
            String(
                localized: "download · \(Formatters.rate(network.outBPS)) up",
                bundle: .strings,
                comment: "Network caption when the figure is set to Download: “download” names the figure, then the upload rate"
            )
        case .upload:
            String(
                localized: "upload · \(Formatters.rate(network.inBPS)) down",
                bundle: .strings,
                comment: "Network caption under the upload figure: download rate"
            )
        }
    }

    private static func batteryCaption(_ battery: BatteryStats?, choice: BatteryFigure) -> String {
        guard let battery else {
            return String(
                localized: "used by apps",
                bundle: .strings,
                comment: "Caption under the apps' total power on a Mac without a battery"
            )
        }
        switch choice {
        case .automatic, .percent, .percentAndTime:
            if battery.source == .ac {
                return battery.isCharging
                    ? String(localized: "Charging", bundle: .strings, comment: "Battery state")
                    : String(localized: "On power adapter", bundle: .strings, comment: "Battery state")
            }
            return battery.timeRemaining.map {
                String(localized: "\(Formatters.duration($0)) remaining", bundle: .strings, comment: "Battery time remaining")
            } ?? String(localized: "Calculating…", bundle: .strings, comment: "Battery time remaining not known yet")
        case .timeLeft, .power:
            let percent = Formatters.percent(battery.percent)
            if battery.source == .battery {
                return String(localized: "\(percent) · on battery", bundle: .strings, comment: "Battery caption: charge, state")
            }
            return battery.isCharging
                ? String(localized: "\(percent) · charging", bundle: .strings, comment: "Battery caption: charge, state")
                : String(localized: "\(percent) · on power adapter", bundle: .strings, comment: "Battery caption: charge, state")
        }
    }

    /// One line of the menu bar window's Overview: the figure and a short note on what it is.
    public func rowValue(_ snapshot: Snapshot, choices: FigureChoices = .automatic) -> String {
        let system = snapshot.system
        let figure = headline(snapshot, choices: choices).figure
        switch self {
        case .cpu, .gpu:
            return figure
        case .memory:
            switch choices.memory {
            case .automatic, .used:
                return String(
                    localized: "\(figure) of \(Formatters.memory(system.memory.totalBytes))",
                    bundle: .strings,
                    comment: "Used memory of total memory, e.g. 18 GB of 48 GB"
                )
            case .percent: return String(localized: "\(figure) used", bundle: .strings, comment: "Percent of memory used")
            case .pressure: return figure
            }
        case .disk:
            switch choices.disk {
            case .automatic, .free: return String(localized: "\(figure) free", bundle: .strings, comment: "Free space on a volume")
            case .percentUsed:
                return system.disk.bootVolume == nil
                    ? figure
                    : String(localized: "\(figure) used", bundle: .strings, comment: "Percent of the startup disk used")
            case .activity:
                return String(
                    localized: "\(figure) read · \(Formatters.rate(system.disk.writeBPS)) write",
                    bundle: .strings,
                    comment: "Disk read rate, write rate"
                )
            }
        case .network:
            switch choices.network {
            case .automatic, .both: return "\(figure) ↓ · \(Formatters.rate(system.network.outBPS)) ↑"
            case .download, .upload: return figure
            }
        case .battery:
            guard let battery = system.battery else {
                return figure
            }
            switch choices.battery {
            case .automatic:
                // No trailing space without a time: values are trailing-aligned.
                return [figure, battery.timeRemaining.map { Formatters.duration($0) }].compactMap(\.self).joined(separator: " ")
            case .percent, .timeLeft, .power: return figure
            case .percentAndTime: return "\(figure) · \(Formatters.batteryTime(battery))"
            }
        }
    }
}
