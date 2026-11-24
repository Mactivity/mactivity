import Core
import Foundation
import Simulated
import Testing
@testable import UI

/// Each source waits here for the others, so the reads can only finish by overlapping. Run one
/// after another, the first waits for a second that hasn't started, until `giveUp` lets everyone
/// go; whoever arrives after that didn't overlap, and doesn't count.
private actor Meeting {
    private let expected: Int
    private var arrived = 0
    private var gaveUp = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var everyoneMet = false

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async {
        arrived += 1
        guard !gaveUp else {
            return
        }
        if arrived == expected {
            everyoneMet = true
            release()
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func giveUp() {
        gaveUp = true
        release()
    }

    private func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private struct MeetingSoftware: InstalledSoftwareSource {
    let meeting: Meeting
    let simulated = SimulatedInstalledSoftware()

    func installed() async -> [InstalledSoftware] {
        await meeting.arrive()
        return await simulated.installed()
    }

    func vulnerabilities() async -> VulnerabilityScan? {
        await simulated.vulnerabilities()
    }

    func upgradePlan(_ formulae: [String]) async -> [String] {
        await simulated.upgradePlan(formulae)
    }

    func upgrade(_ confirmation: UpgradeConfirmation) async -> UpgradeResult {
        await simulated.upgrade(confirmation)
    }
}

private struct MeetingReports: MacReportSource {
    let meeting: Meeting
    let simulated = SimulatedMacReports()

    func macReports(since: Date) async -> [MacReport] {
        await meeting.arrive()
        return await simulated.macReports(since: since)
    }
}

private struct MeetingSecurity: SecuritySource {
    let meeting: Meeting
    let simulated = SimulatedSecurity()

    func settings() async -> SecuritySettings {
        await meeting.arrive()
        return await simulated.settings()
    }

    func permissions() async -> PermissionsReading {
        await simulated.permissions()
    }

    func systemExtensions() async -> [SystemExtensionItem] {
        await simulated.systemExtensions()
    }

    func browserExtensions() async -> BrowserExtensionsReading {
        await simulated.browserExtensions()
    }
}

/// Checkup's slow reads run together, and what they find still arrives (D-267).
@MainActor
@Suite("Checkup loader")
struct CheckupLoaderTests {
    @Test("The slow reads overlap, and each one's result reaches Checkup")
    func slowReadsOverlap() async {
        let servers = SimulatedDevServers()
        let services = AppServices(
            metrics: .preview(), history: SimulatedThirtyDayHistory(apps: SimulatedHistoryStore()), alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults, projects: servers, terminator: servers
        )
        let meeting = Meeting(expected: 3)
        services.software.setSource(MeetingSoftware(meeting: meeting))
        services.macReports = MeetingReports(meeting: meeting)
        services.securitySource = MeetingSecurity(meeting: meeting)
        // The fourth slow read walks real folders; a kept value keeps this test off this Mac's disk.
        CleanupSummary.cached = (Date(), Reclaimable())
        defer { CleanupSummary.invalidate() }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            await meeting.giveUp()
        }
        defer { timeout.cancel() }

        let inputs = await CheckupLoader.inputs(services)

        #expect(await meeting.everyoneMet)
        let now = Date()
        #expect(inputs.software.count == services.software.findings(now: now).count)
        #expect(await inputs.flagged.count == (SimulatedMacReports().macReports(since: now.addingTimeInterval(-7 * 86400))).count)
        #expect(await inputs.security == (SimulatedSecurity().settings()))
    }
}
