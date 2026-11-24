import Foundation

/// One thing that happened on a day (D-191): when, until when if it lasted, and what.
public struct DayEvent: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Woke from sleep, and why if macOS said.
        case wake(WakeCause?)
        case sleep
        /// The processor busy for a stretch, but not struggling: its highest bucket average.
        case busy(peak: Double)
        /// A slowdown (D-169), most telling cause first.
        case slowdown([SlowSpell.Cause])
        /// Off the charger, and the charge then.
        case unplugged(level: Double?)
        case pluggedIn(level: Double?)
        /// An hour that downloaded a lot: its bytes.
        case download(bytes: Double)
        /// An alert, and how many times that same alert fired that day.
        case alert(title: String, app: AppIdentity, count: Int)
        case crash(app: String, hang: Bool)
        /// A coding agent at work in a project (D-192); the project is empty when unknown.
        case agent(name: String, project: String)
        /// Offline, or on a hotspot, a VPN or Ethernet for a while (D-233).
        case network(NetworkKind)
        /// The person's note (D-253).
        case note(id: UUID, text: String)
        /// An app used the camera, a microphone or recorded the screen (D-259); nil when macOS
        /// didn't say which app.
        case sensor(sensors: [PrivacySensor], app: String?)
    }

    public let start: Date
    /// When it ended, for stretches; nil for moments.
    public let end: Date?
    public let kind: Kind

    public init(start: Date, end: Date? = nil, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }

    public var id: String {
        "\(start.timeIntervalSince1970):\(kind)"
    }

    /// Stretches whose apps are worth naming: what kept the processor or memory busy.
    public var appMetric: Metric? {
        switch kind {
        case .busy: .cpu
        case let .slowdown(causes): causes.first?.metric ?? .cpu
        default: nil
        }
    }
}

/// What a day's story is made from: History's series for it and the day's events, all already
/// recorded. Each series is the whole Mac's, one point per bucket.
public struct DayStoryInputs: Sendable {
    public var day: DateInterval
    /// The series' spacing: 60 for minutes, 900 for quarter-hours.
    public var bucket: TimeInterval
    public var power: [PowerEvent] = []
    public var cpu: [SeriesPoint] = []
    public var memoryPressure: [SeriesPoint] = []
    public var thermal: [SeriesPoint] = []
    /// 1 on battery, 0 on power, averaged over each bucket.
    public var onBattery: [SeriesPoint] = []
    public var batteryLevel: [SeriesPoint] = []
    /// Bytes a second received, averaged over each bucket.
    public var netIn: [SeriesPoint] = []
    public var alerts: [Alert] = []
    public var crashes: [CrashReport] = []
    /// Agent history's quarter-hours for the day (D-192).
    public var agents: [AgentUsage] = []
    /// The day's network changes, with the one before it (D-233).
    public var networkChanges: [NetworkChange] = []
    /// The person's notes that day (D-253).
    public var notes: [HistoryNote] = []
    /// What the privacy indicators showed that day (D-259), with the change before it.
    public var sensorChanges: [SensorChange] = []

    public init(day: DateInterval, bucket: TimeInterval) {
        self.day = day
        self.bucket = bucket
    }
}

/// A day as a list of what happened (D-191). Pure: History's points in, events out, oldest first.
public enum DayStory {
    /// A bucket averaging this much processor is busy, short of a slowdown's 80%.
    public static let busyCPU = 50.0
    /// Busy for less than this (one quarter-hour) isn't worth a line.
    public static let minimumBusy: TimeInterval = 30 * 60
    /// An hour that downloaded at least this much counts; an evening of video doesn't.
    public static let bigDownload = 2e9

    /// A screen recording shorter than this is a screenshot: not worth a line.
    public static let minimumScreenRecording: TimeInterval = 60

    /// The camera, microphone and screen recordings that began that day (D-259); the location
    /// is left out, as on the Devices page.
    static func sensors(_ changes: [SensorChange], day: DateInterval) -> [DayEvent] {
        let sessions = SensorSessions.sessions(changes, from: day.start, now: day.end)
        return SensorMoment.moments(sessions, now: day.end).compactMap { moment in
            guard moment.start >= day.start, moment.start < day.end else {
                return nil
            }
            let length = (moment.end ?? day.end).timeIntervalSince(moment.start)
            if moment.sensors == [.screen], length < minimumScreenRecording {
                return nil
            }
            return DayEvent(start: moment.start, end: moment.end, kind: .sensor(sensors: moment.sensors, app: moment.app))
        }
    }

    public static func events(_ inputs: DayStoryInputs) -> [DayEvent] {
        let day = inputs.day
        func inDay(_ date: Date) -> Bool {
            date >= day.start && date < day.end
        }
        var events: [DayEvent] = []
        for event in inputs.power where inDay(event.at) {
            events.append(DayEvent(
                start: event.at, kind: event.kind == .sleep ? .sleep : .wake(event.reason.map(WakeCause.init(reason:)))
            ))
        }
        let spells = SlowSpells.find(
            cpu: inputs.cpu.filter { inDay($0.at) }, memoryPressure: inputs.memoryPressure.filter { inDay($0.at) },
            thermal: inputs.thermal.filter { inDay($0.at) }, bucket: inputs.bucket
        )
        events += spells.map { DayEvent(start: $0.start, end: $0.end, kind: .slowdown($0.causes)) }
        events += busy(inputs.cpu.filter { inDay($0.at) }, bucket: inputs.bucket, apartFrom: spells)
        events += charging(inputs.onBattery.filter { inDay($0.at) }, levels: inputs.batteryLevel)
        events += downloads(inputs.netIn.filter { inDay($0.at) }, bucket: inputs.bucket)
        events += alerts(inputs.alerts.filter { inDay($0.firedAt) })
        events += inputs.crashes.filter { inDay($0.at) }.map {
            DayEvent(start: $0.at, kind: .crash(app: $0.appName, hang: $0.kind == .hang))
        }
        events += AgentWeek.stretches(inputs.agents.filter { inDay($0.start) }).map {
            DayEvent(start: $0.start, end: $0.end, kind: .agent(name: $0.agent, project: $0.project))
        }
        events += network(inputs.networkChanges, day: day)
        events += inputs.notes.filter { inDay($0.at) }.map { DayEvent(start: $0.at, kind: .note(id: $0.id, text: $0.text)) }
        events += sensors(inputs.sensorChanges, day: day)
        return events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Network stretches worth telling (D-233, D-236): a drop of a minute or more, not the one
    /// around a sleep (the path goes before the Mac does); time on a hotspot; and a VPN or
    /// Ethernet when it isn't the day's usual (a desktop on Ethernet, an always-on VPN).
    /// Wi-Fi is the usual, so it isn't an event.
    static func network(_ changes: [NetworkChange], day: DateInterval) -> [DayEvent] {
        let sessions = NetworkSession.sessions(changes, from: day.start, now: day.end).reversed().filter { $0.start < day.end }
        func length(_ session: NetworkSession) -> TimeInterval {
            min(session.end ?? day.end, day.end).timeIntervalSince(session.start)
        }
        var time: [NetworkKind: TimeInterval] = [:]
        for session in sessions where session.kind != .asleep && session.kind != .offline {
            time[session.kind, default: 0] += length(session)
        }
        let connected = time.values.reduce(0, +)
        let usual = time.max { $0.value < $1.value }.flatMap { connected > 0 && $0.value / connected > 0.5 ? $0.key : nil }
        let ordered = Array(sessions)
        return ordered.indices.compactMap { index in
            let session = ordered[index]
            let end = min(session.end ?? day.end, day.end)
            switch session.kind {
            case .offline:
                let nearSleep = (index > 0 && ordered[index - 1].kind == .asleep)
                    || (index + 1 < ordered.count && ordered[index + 1].kind == .asleep)
                return length(session) >= 60 && !nearSleep ? DayEvent(start: session.start, end: end, kind: .network(.offline)) : nil
            case .hotspot:
                return DayEvent(start: session.start, end: end, kind: .network(.hotspot))
            case .vpn, .ethernet:
                return session.kind == usual ? nil : DayEvent(start: session.start, end: end, kind: .network(session.kind))
            default:
                return nil
            }
        }
    }

    /// Runs of buckets at `busyCPU` or more, a missing bucket allowed inside one, at least
    /// `minimumBusy` long, and not where a slowdown already tells it.
    static func busy(_ cpu: [SeriesPoint], bucket: TimeInterval, apartFrom spells: [SlowSpell]) -> [DayEvent] {
        var runs: [(start: Date, end: Date, peak: Double)] = []
        for point in cpu.sorted(by: { $0.at < $1.at }) where point.average >= busyCPU {
            let end = point.at.addingTimeInterval(bucket)
            if let last = runs.last, point.at.timeIntervalSince(last.end) <= bucket {
                runs[runs.count - 1] = (last.start, end, max(last.peak, point.average))
            } else {
                runs.append((point.at, end, point.average))
            }
        }
        return runs
            .filter { $0.end.timeIntervalSince($0.start) >= minimumBusy }
            .filter { run in !spells.contains { $0.start < run.end && $0.end > run.start } }
            .map { DayEvent(start: $0.start, end: $0.end, kind: .busy(peak: $0.peak)) }
    }

    /// One line per alert, however often it repeated: at its first time, with the count. A day of
    /// "Safari's memory keeps climbing" every hour is one line, not ten.
    static func alerts(_ alerts: [Alert]) -> [DayEvent] {
        var first: [String: Alert] = [:]
        var counts: [String: Int] = [:]
        for alert in alerts.sorted(by: { $0.firedAt < $1.firedAt }) {
            first[alert.title] = first[alert.title] ?? alert
            counts[alert.title, default: 0] += 1
        }
        return first.values.map { alert in
            DayEvent(start: alert.firedAt, kind: .alert(title: alert.title, app: alert.app, count: counts[alert.title] ?? 1))
        }
    }

    /// Each change between the charger and the battery, with the charge at that moment.
    static func charging(_ onBattery: [SeriesPoint], levels: [SeriesPoint]) -> [DayEvent] {
        let sorted = onBattery.sorted { $0.at < $1.at }
        var events: [DayEvent] = []
        for (before, after) in zip(sorted, sorted.dropFirst()) {
            let was = before.average >= 0.5
            let now = after.average >= 0.5
            guard was != now else {
                continue
            }
            let level = levels.min { abs($0.at.timeIntervalSince(after.at)) < abs($1.at.timeIntervalSince(after.at)) }?.average
            events.append(DayEvent(start: after.at, kind: now ? .unplugged(level: level) : .pluggedIn(level: level)))
        }
        return events
    }

    /// Hours that received at least `bigDownload`, back-to-back ones as one stretch with their
    /// total: a long download is one line, not one an hour.
    static func downloads(_ netIn: [SeriesPoint], bucket: TimeInterval) -> [DayEvent] {
        let calendar = Calendar.current
        var byHour: [Date: Double] = [:]
        for point in netIn {
            let hour = calendar.dateInterval(of: .hour, for: point.at)?.start ?? point.at
            byHour[hour, default: 0] += point.average * bucket
        }
        var runs: [(start: Date, end: Date, bytes: Double)] = []
        for (hour, bytes) in byHour.sorted(by: { $0.key < $1.key }) where bytes >= bigDownload {
            let end = hour.addingTimeInterval(3600)
            if let last = runs.last, last.end == hour {
                runs[runs.count - 1] = (last.start, end, last.bytes + bytes)
            } else {
                runs.append((hour, end, bytes))
            }
        }
        return runs.map { DayEvent(start: $0.start, end: $0.end, kind: .download(bytes: $0.bytes)) }
    }
}
