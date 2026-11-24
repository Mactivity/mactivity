import Alerts
import Core
import Foundation
import Projects
import Readouts
import UI

/// Agent history's recording (D-192): once a minute, window or not, the running agent sessions
/// into the current quarter-hour. One process-table read a minute; a write only while an agent
/// runs. Its own source, so the processor figures are a minute's, not whatever the Agents tab
/// last read.
@MainActor
final class AgentHistoryRecorder {
    private let source: any AgentSource
    private var usage = AgentUsageAccumulator()

    init(source: any AgentSource) {
        self.source = source
    }

    private var seeded = false

    func observe(_ snapshot: Snapshot, store: any HistoryStore, monitor: AlertMonitor? = nil) async {
        guard usage.isNewMinute(snapshot.at), let agents = store as? any AgentHistoryStore else {
            return
        }
        if !seeded {
            seeded = true
            let quarter = Date(timeIntervalSince1970: (snapshot.at.timeIntervalSince1970 / 900).rounded(.down) * 900)
            let stored = await (try? agents.agentUsage(from: quarter, to: quarter.addingTimeInterval(900))) ?? []
            usage.seed(stored, at: snapshot.at)
        }
        let sessions = await (try? source.sessions()) ?? []
        let rows = usage.add(sessions, at: snapshot.at)
        if !rows.isEmpty {
            try? await agents.recordAgentUsage(rows)
        }
        // Agent limits (D-227): only sessions past one go to the rules, which fire each once.
        let settings = AppModel.shared.services.alertSettings
        let long = settings.settings(for: .agentLongSession)
        let memory = settings.settings(for: .agentMemory)
        let past = sessions.filter { session in
            (long.isEnabled && snapshot.at.timeIntervalSince(session.startedAt) >= long.threshold * 3600)
                || (memory.isEnabled && Double(session.memoryBytes) >= memory.threshold)
        }
        if let monitor, !past.isEmpty {
            await monitor.checkSystem(SystemAlertInputs(agentSessions: past), now: snapshot.at)
        }
    }
}

/// Build times' recording (D-209): each snapshot's compiler processes, by project, into builds.
/// A name check of each process every snapshot, and a folder lookup per new compiler; a write
/// when a build ends. Test runs too (D-278): the same name check, one argument read per new
/// `node`, `python`, `cargo` or `swift-test`, and one kernel event when a test command exits.
@MainActor
final class BuildRecorder {
    /// The running pipeline's, so quitting can save a build still under way.
    weak static var current: BuildRecorder?
    private var locator = CompilerLocator()
    private var tracker = BuildTracker()
    private var store: (any BuildHistoryStore)?
    private var testLocator = TestRunLocator()
    private var testTracker = TestRunTracker()
    private let testExits = ProcessExitWatcher()

    init() {
        Self.current = self
    }

    /// Records any build still open: Mactivity is quitting.
    func finish() async {
        for run in tracker.finishAll() {
            try? await store?.recordBuildRun(run)
        }
    }

    func observe(_ snapshot: Snapshot, store: any HistoryStore) async {
        guard let builds = store as? any BuildHistoryStore else {
            return
        }
        self.store = builds
        let compilers = locator.compilers(in: snapshot)
        let interval = Double(snapshot.interval.components.seconds) + Double(snapshot.interval.components.attoseconds) / 1e18
        for run in tracker.observe(compilers, at: snapshot.at, interval: interval) {
            try? await builds.recordBuildRun(run)
        }
        let tests = testLocator.processes(in: snapshot)
        for test in tests {
            testExits.watch(test.pid)
        }
        for run in testTracker.observe(tests, exits: testExits.drain(), at: snapshot.at, interval: interval) {
            try? await builds.recordBuildRun(run)
        }
    }
}

/// Today so far for the desktop widget (D-200): the day's events every 15 minutes, from the same
/// reader as Your day, while the app runs. Only with a widget feed (signed builds).
@MainActor
final class TodayWidgetUpdater {
    private let feed: WidgetFeed
    private var lastRead: Date?
    static let interval: TimeInterval = 15 * 60

    init(feed: WidgetFeed) {
        self.feed = feed
    }

    func observe(_ snapshot: Snapshot, services: AppServices) async {
        if let lastRead, lastRead <= snapshot.at, snapshot.at.timeIntervalSince(lastRead) < Self.interval, Calendar.current.isDate(
            lastRead,
            inSameDayAs: snapshot.at
        ) {
            return
        }
        lastRead = snapshot.at
        let dayStart = Calendar.current.startOfDay(for: snapshot.at)
        let crashed = await CrashFilter.relevant(services.crashReports.reports(since: dayStart))
        let result = await DayStoryReader.read(
            day: snapshot.at, now: snapshot.at, history: services.history, hasBattery: services.metrics.hardware.hasBattery,
            alerts: services.alertLog, crashes: crashed
        )
        feed.updateToday(WidgetSnapshot.Today(result, dayStart: dayStart))
    }
}
