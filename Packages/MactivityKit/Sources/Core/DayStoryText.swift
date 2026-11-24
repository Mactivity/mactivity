import Foundation

/// Plain English for a day's events (D-193, D-199): the command line's output and what the
/// on-device model reads, the same in every locale. The app's own words are localized
/// (DayEventText).
extension DayEvent.Kind {
    /// A stable name for JSON: "wake", "plugged_in"…
    public var code: String {
        switch self {
        case .wake: "wake"
        case .sleep: "sleep"
        case .busy: "busy"
        case .slowdown: "slowdown"
        case .unplugged: "unplugged"
        case .pluggedIn: "plugged_in"
        case .download: "download"
        case .alert: "alert"
        case .crash: "crash"
        case .agent: "agent"
        case .network: "network"
        case .note: "note"
        case .sensor: "sensor"
        }
    }

    public var englishText: String {
        switch self {
        case let .wake(cause): cause.map { "Woke up (\(Self.wake($0)))" } ?? "Woke up"
        case .sleep: "Went to sleep"
        case let .busy(peak): "Busy, the processor up to \(Int(peak.rounded()))%"
        case let .slowdown(causes): "Slowdown: " + causes.map(Self.cause).joined(separator: ", ")
        case let .unplugged(level): level.map { "Unplugged at \(Int($0.rounded()))%" } ?? "Unplugged"
        case let .pluggedIn(level): level.map { "Plugged in at \(Int($0.rounded()))%" } ?? "Plugged in"
        case let .download(bytes): "Downloaded \(Int64(bytes).formatted(.byteCount(style: .file).locale(Self.english)))"
        case let .alert(title, _, count): count > 1 ? "\(title) ×\(count)" : title
        case let .crash(app, hang): hang ? "\(app) stopped responding" : "\(app) quit unexpectedly"
        case let .agent(name, project): project.isEmpty ? name : "\(name) in \(project)"
        case let .network(kind):
            switch kind {
            case .offline: "Offline"
            case .hotspot: "On Personal Hotspot"
            case .vpn: "On a VPN"
            case .ethernet: "On Ethernet"
            case .wifi, .cellular, .other: "On \(kind.rawValue)"
            case .asleep: "Asleep"
            }
        case let .note(_, text): "Note: \(text)"
        case let .sensor(sensors, app):
            "\(app ?? "An app") used the " + sensors.map(Self.sensor).joined(separator: " and ")
        }
    }

    /// The English lines' numbers: "1.2 GB" on a French Mac too, as the rest of them are English.
    private static let english = Locale(identifier: "en_US_POSIX")

    private static func wake(_ cause: WakeCause) -> String {
        switch cause {
        case .lid: "lid opened"
        case .powerButton: "power button"
        case .keyboardOrTrackpad: "keyboard or trackpad"
        case .powerAdapter: "power adapter connected"
        case .network: "network access"
        case .bluetooth: "a Bluetooth device"
        case .usb: "a USB device"
        case .scheduled: "scheduled"
        case .other: "other"
        }
    }

    private static func sensor(_ sensor: PrivacySensor) -> String {
        switch sensor {
        case .camera: "camera"
        case .microphone: "microphone"
        case .screen: "screen (recording)"
        case .location: "location"
        }
    }

    private static func cause(_ cause: SlowSpell.Cause) -> String {
        switch cause {
        case .cpu: "processor near full"
        case .memory: "memory ran short"
        case .heat: "slowed down to stay cool"
        }
    }
}

extension DayStoryResult {
    /// The day as lines of plain English, one per event, with the apps behind each stretch.
    public func englishLines(calendar: Calendar = .current) -> [String] {
        events.map { event in
            let start = event.start.formatted(date: .omitted, time: .shortened)
            let time = event.end.map { "\(start)–\($0.formatted(date: .omitted, time: .shortened))" } ?? start
            let names = (apps[event.id] ?? []).map(\.name)
            return "\(time): \(event.kind.englishText)" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
        }
    }
}
