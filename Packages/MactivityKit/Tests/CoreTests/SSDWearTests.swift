import Core
import Foundation
import Testing

@Suite("What wears your SSD (D-281)")
struct SSDWearTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func total(_ name: String, _ value: Double) -> AppTotal {
        AppTotal(app: AppIdentity(id: name, name: name, bundleID: name, iconKey: name, kind: .app), value: value)
    }

    private func drive(_ model: String, isInternal: Bool, written: UInt64) -> DriveHealth {
        DriveHealth(
            index: 0, model: model, isInternal: isInternal, percentUsed: 1, availableSpare: 100, spareThreshold: 10, criticalWarning: 0,
            temperatureCelsius: nil, bytesRead: 0, bytesWritten: written, powerOnHours: 1, unsafeShutdowns: 0, mediaErrors: 0
        )
    }

    @Test("Apps by what they wrote, most first, nothing that wrote nothing, up to the limit")
    func ranking() {
        let report = SSDWearReport.make(
            totals: [total("a", 1), total("b", 3), total("none", 0), total("c", 2)],
            allDrivesWritten: 10, firstRecorded: nil, drives: [], now: now, limit: 2
        )
        #expect(report.writers.map(\.app.id) == ["b", "c"])
        #expect(report.allDrivesWritten == 10)
    }

    @Test("Only the internal drive's own figure, never an external one's")
    func internalOnly() {
        let external = drive("Samsung T7", isInternal: false, written: 9)
        let inside = drive("APPLE SSD", isInternal: true, written: 7)
        let report = SSDWearReport.make(totals: [], allDrivesWritten: 0, firstRecorded: nil, drives: [external, inside], now: now)
        #expect(report.internalDrive?.bytesWritten == 7)
        let none = SSDWearReport.make(totals: [], allDrivesWritten: 0, firstRecorded: nil, drives: [external], now: now)
        #expect(none.internalDrive == nil)
    }

    @Test("History younger than 30 days says when it starts")
    func startsLate() {
        let started = now.addingTimeInterval(-5 * 86400)
        let late = SSDWearReport.make(totals: [], allDrivesWritten: 0, firstRecorded: started, drives: [], now: now)
        #expect(late.startsLate)
        #expect(late.since == started)
        let old = now.addingTimeInterval(-90 * 86400)
        let whole = SSDWearReport.make(totals: [], allDrivesWritten: 0, firstRecorded: old, drives: [], now: now)
        #expect(!whole.startsLate)
        #expect(whole.since == now.addingTimeInterval(-SSDWearReport.span))
    }
}
