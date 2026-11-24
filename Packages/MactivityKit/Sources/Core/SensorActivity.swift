import Foundation

/// What macOS's privacy indicators watch (1.8, D-259): the camera, a microphone, the screen being
/// recorded, and the location.
public enum PrivacySensor: String, CaseIterable, Sendable, Hashable, Codable, Comparable {
    case camera, microphone, screen, location

    public var title: String {
        switch self {
        case .camera: String(localized: "Camera", bundle: .strings, comment: "Privacy sensor")
        case .microphone: String(localized: "Microphone", bundle: .strings, comment: "Privacy sensor")
        case .screen: String(localized: "Screen recording", bundle: .strings, comment: "Privacy sensor: an app recording the screen")
        case .location: String(localized: "Location", bundle: .strings, comment: "Privacy sensor: an app reading where the Mac is")
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screen: "rectangle.dashed.badge.record"
        case .location: "location.fill"
        }
    }

    /// The short code macOS's indicators use for it: "cam:us.zoom.xos".
    public var code: String {
        switch self {
        case .camera: "cam"
        case .microphone: "mic"
        case .screen: "scr"
        case .location: "loc"
        }
    }

    public init?(code: String) {
        guard let sensor = Self.allCases.first(where: { $0.code == code }) else {
            return nil
        }
        self = sensor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// A sensor in use by an app. `app` is its bundle ID, or nil when only the sensor is known (the
/// public fallback, D-259).
public struct SensorUse: Hashable, Sendable, Codable {
    public let sensor: PrivacySensor
    public let app: String?

    public init(sensor: PrivacySensor, app: String?) {
        self.sensor = sensor
        self.app = app
    }

    /// "cam:us.zoom.xos", or "cam:" when the app isn't known.
    public var code: String {
        "\(sensor.code):\(app ?? "")"
    }

    /// Pure: from "cam:us.zoom.xos". Nil for a sensor Mactivity doesn't know.
    public init?(code: String) {
        let parts = code.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let sensor = PrivacySensor(code: String(parts[0])) else {
            return nil
        }
        self.sensor = sensor
        app = parts[1].isEmpty ? nil : String(parts[1])
    }
}

/// What was in use from `at` until the next change (D-259). Empty: nothing.
public struct SensorChange: Hashable, Sendable {
    public let at: Date
    public let active: Set<SensorUse>

    public init(at: Date, active: Set<SensorUse>) {
        self.at = at
        self.active = active
    }

    /// Pure: the set as one string, sorted, for storage: "cam:us.zoom.xos,mic:us.zoom.xos".
    public var encoded: String {
        active.map(\.code).sorted().joined(separator: ",")
    }

    /// Pure: from `encoded`; codes Mactivity doesn't know are left out.
    public init(at: Date, encoded: String) {
        self.at = at
        active = Set(encoded.split(separator: ",").compactMap { SensorUse(code: String($0)) })
    }
}

/// One app's stretch with one sensor (D-259).
public struct SensorSession: Hashable, Sendable, Identifiable {
    public let sensor: PrivacySensor
    public let app: String?
    public let start: Date
    /// Nil while it's still in use.
    public let end: Date?

    public var id: String {
        "\(sensor.code):\(app ?? ""):\(start.timeIntervalSince1970)"
    }

    public init(sensor: PrivacySensor, app: String?, start: Date, end: Date?) {
        self.sensor = sensor
        self.app = app
        self.start = start
        self.end = end
    }

    public func length(now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

public enum SensorSessions {
    /// A gap shorter than this between two of an app's stretches with a sensor is one stretch:
    /// a call that drops the microphone for a moment is still one call.
    public static let joinGap: TimeInterval = 30

    /// Pure: the changes as stretches, newest first. Stretches that ended before `from` are left
    /// out; one that began before it keeps its real start.
    public static func sessions(_ changes: [SensorChange], from: Date, now: Date) -> [SensorSession] {
        var open: [SensorUse: Date] = [:]
        var closed: [SensorSession] = []
        for change in changes.sorted(by: { $0.at < $1.at }) {
            for (use, start) in open where !change.active.contains(use) {
                closed.append(SensorSession(sensor: use.sensor, app: use.app, start: start, end: change.at))
                open[use] = nil
            }
            for use in change.active where open[use] == nil {
                open[use] = change.at
            }
        }
        let ongoing = open.map { SensorSession(sensor: $0.key.sensor, app: $0.key.app, start: $0.value, end: nil) }
        return joined(closed + ongoing)
            .filter { ($0.end ?? now) > from }
            .sorted { ($0.start, $0.sensor) > ($1.start, $1.sensor) }
    }

    /// Pure: an app's stretches with a sensor that are under `joinGap` apart, as one.
    static func joined(_ sessions: [SensorSession]) -> [SensorSession] {
        let groups = Dictionary(grouping: sessions) { SensorUse(sensor: $0.sensor, app: $0.app) }
        return groups.values.flatMap { group in
            var merged: [SensorSession] = []
            for session in group.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, let end = last.end, session.start.timeIntervalSince(end) < joinGap {
                    merged[merged.count - 1] = SensorSession(sensor: last.sensor, app: last.app, start: last.start, end: session.end)
                } else {
                    merged.append(session)
                }
            }
            return merged
        }
    }

    /// Pure: each app's time with each sensor within `from`…`now`, longest first.
    public static func totals(_ sessions: [SensorSession], from: Date, now: Date) -> [SensorTotal] {
        var seconds: [SensorUse: TimeInterval] = [:]
        var counts: [SensorUse: Int] = [:]
        var last: [SensorUse: Date] = [:]
        for session in sessions {
            let use = SensorUse(sensor: session.sensor, app: session.app)
            let start = max(session.start, from)
            let end = min(session.end ?? now, now)
            guard end > start else {
                continue
            }
            seconds[use, default: 0] += end.timeIntervalSince(start)
            counts[use, default: 0] += 1
            last[use] = max(last[use] ?? .distantPast, session.end ?? now)
        }
        return seconds.map { use, total in
            SensorTotal(sensor: use.sensor, app: use.app, seconds: total, times: counts[use] ?? 0, lastUsed: last[use] ?? now)
        }
        .sorted { ($0.seconds, $1.app ?? "") > ($1.seconds, $0.app ?? "") }
    }
}

/// An app's time with a sensor over a span (D-259).
public struct SensorTotal: Hashable, Sendable, Identifiable {
    public let sensor: PrivacySensor
    public let app: String?
    public let seconds: TimeInterval
    /// How many separate stretches.
    public let times: Int
    public let lastUsed: Date

    public var id: String {
        "\(sensor.code):\(app ?? "")"
    }

    public init(sensor: PrivacySensor, app: String?, seconds: TimeInterval, times: Int, lastUsed: Date) {
        self.sensor = sensor
        self.app = app
        self.seconds = seconds
        self.times = times
        self.lastUsed = lastUsed
    }
}

/// Where sensor changes are kept (D-259): History's real store, and the simulated one.
public protocol SensorHistoryStore: Sendable {
    func recordSensorChanges(_ changes: [SensorChange]) async throws
    /// Changes in the span, oldest first, plus the last one before it: what the span began with.
    func sensorChanges(from: Date, to: Date) async throws -> [SensorChange]
    /// The newest change kept, if any: where the next read of macOS's log starts.
    func lastSensorChange() async throws -> SensorChange?
}

/// Where sensor use is read from (D-259).
public protocol SensorActivitySource: Sendable {
    /// Which sensors are running right now, from public API: cheap, for every few samples.
    func inUse() -> Set<PrivacySensor>
    /// Each change in what was in use, by app, between the two dates, from macOS's own record.
    /// Nil when that record can't be read: the caller then records `inUse()` without the apps.
    func changes(from: Date, to: Date) async -> [SensorChange]?
}

/// One app's use of the camera, a microphone or the screen at one time: a video call's camera
/// and microphone are one moment, not two rows (D-259).
public struct SensorMoment: Hashable, Sendable, Identifiable {
    public let app: String?
    public let sensors: [PrivacySensor]
    public let start: Date
    public let end: Date?

    public init(app: String?, sensors: [PrivacySensor], start: Date, end: Date?) {
        self.app = app
        self.sensors = sensors
        self.start = start
        self.end = end
    }

    public var id: String {
        "\(app ?? ""):\(start.timeIntervalSince1970)"
    }

    /// Pure: the sessions as moments, newest first. An app's sessions that overlap are one
    /// moment; location is left out (apps check it for seconds, many times a day: it's in the
    /// totals instead).
    public static func moments(_ sessions: [SensorSession], now: Date) -> [SensorMoment] {
        var moments: [SensorMoment] = []
        for session in sessions.filter({ $0.sensor != .location }).sorted(by: { $0.start < $1.start }) {
            let index = moments.lastIndex { moment in
                moment.app == session.app && session.start <= (moment.end ?? now)
            }
            if let index {
                let moment = moments[index]
                let end: Date? = moment.end == nil || session.end == nil ? nil : max(moment.end ?? now, session.end ?? now)
                moments[index] = SensorMoment(
                    app: moment.app, sensors: Array(Set(moment.sensors + [session.sensor])).sorted(), start: moment.start, end: end
                )
            } else {
                moments.append(SensorMoment(app: session.app, sensors: [session.sensor], start: session.start, end: session.end))
            }
        }
        return moments.reversed()
    }
}
