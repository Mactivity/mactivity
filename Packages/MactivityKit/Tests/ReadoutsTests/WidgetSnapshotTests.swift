import Core
import Foundation
@testable import Readouts
import Testing

@Suite("Widget snapshot codec")
struct WidgetSnapshotTests {
    @Test("Built from a snapshot: figures, battery, top 3 by CPU without macOS")
    func fromSnapshot() throws {
        let widget = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: [10, 20, 30])
        #expect(widget.version == 1)
        #expect(widget.cpuPercent == 23.4)
        #expect(widget.cpuHistory == [10, 20, 30])
        #expect(widget.memoryUsedBytes == 19_327_352_832)
        #expect(widget.memoryTotalBytes == 51_539_607_552)
        #expect(widget.memoryUsedPercent == 37.5)
        #expect(widget.battery == WidgetSnapshot.Battery(percent: 87, isCharging: true, onAC: true))
        #expect(widget.topApps.map(\.name) == ["Xcode", "node", "Safari"])
        #expect(widget.topApps.first?.bundleID == "com.apple.dt.Xcode")
    }

    @Test("History keeps the newest 30 points")
    func historyCap() throws {
        let widget = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: (0 ..< 45).map(Double.init))
        #expect(widget.cpuHistory.count == 30)
        #expect(widget.cpuHistory.first == 15)
    }

    @Test("Round trip, with sorted keys and ISO 8601 dates")
    func roundTrip() throws {
        let widget = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: [1.5])
        let data = try widget.encoded()
        #expect(WidgetSnapshot.decode(data) == widget)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("\"updatedAt\":\"2026-09-25T10:00:00Z\""))
        #expect(text.hasPrefix("{\"battery\":"))
    }

    @Test("Today so far rides along (D-200); a file without it still reads, as before")
    func today() throws {
        var widget = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: [1.5])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        widget.today = WidgetSnapshot.Today(dayStart: start, activeSeconds: 7200, marks: [
            .init(start: start + 3600, end: nil, kind: "wake"),
            .init(start: start + 7200, end: start + 9000, kind: "agent"),
        ])
        #expect(try WidgetSnapshot.decode(widget.encoded()) == widget)
        widget.today = nil
        let old = try widget.encoded()
        #expect(String(bytes: old, encoding: .utf8)?.contains("today") == false)
        #expect(WidgetSnapshot.decode(old)?.today == nil)
    }

    @Test("A desktop Mac has no battery key")
    func noBattery() throws {
        let snapshot = try Fixtures.variant(of: Fixtures.snapshot(), battery: .some(nil))
        let widget = WidgetSnapshot(snapshot: snapshot, cpuHistory: [])
        #expect(widget.battery == nil)
        #expect(try WidgetSnapshot.decode(widget.encoded())?.battery == nil)
    }

    @Test("The GPU figure travels, for the desktop widget's third figure; files without it still read")
    func gpu() throws {
        let snapshot = try Fixtures.snapshot()
        let widget = WidgetSnapshot(snapshot: snapshot, cpuHistory: [])
        #expect(widget.gpuPercent == snapshot.system.gpu?.utilizationPercent)
        var older = widget
        older.gpuPercent = nil
        let data = try older.encoded()
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("gpuPercent"))
        #expect(WidgetSnapshot.decode(data)?.gpuPercent == nil)
    }

    @Test("A desktop's widget rewrites when the GPU moves, as a laptop's does for the battery")
    func gpuChange() throws {
        var old = try WidgetSnapshot(snapshot: Fixtures.variant(of: Fixtures.snapshot(), battery: .some(nil)), cpuHistory: [])
        old.gpuPercent = 10
        var near = old
        near.gpuPercent = 12
        var far = old
        far.gpuPercent = 40
        #expect(!WidgetPublishPolicy.standard.changedMeaningfully(from: old, to: near))
        #expect(WidgetPublishPolicy.standard.changedMeaningfully(from: old, to: far))
    }

    @Test("Garbage, truncation, and unknown versions decode to nil")
    func rejects() throws {
        #expect(WidgetSnapshot.decode(Data("not json".utf8)) == nil)
        let data = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: []).encoded()
        #expect(WidgetSnapshot.decode(data.prefix(data.count / 2)) == nil)
        var future = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: [])
        future.version = 2
        #expect(try WidgetSnapshot.decode(future.encoded()) == nil)
    }

    @Test("Missing file loads as nil")
    func missingFile() {
        #expect(WidgetSnapshot.load(from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")) == nil)
    }

    @Test("Stale after 90 minutes")
    func stale() throws {
        let widget = try WidgetSnapshot(snapshot: Fixtures.snapshot(), cpuHistory: [])
        #expect(!widget.isStale(now: widget.updatedAt.addingTimeInterval(89 * 60)))
        #expect(widget.isStale(now: widget.updatedAt.addingTimeInterval(90 * 60)))
    }

    @Test("The app group needs a team; ad-hoc builds have none")
    func appGroup() {
        #expect(WidgetSnapshot.appGroupIdentifier(teamID: nil) == nil)
        #expect(WidgetSnapshot.appGroupIdentifier(teamID: "") == nil)
        #expect(WidgetSnapshot.appGroupIdentifier(teamID: "ABCDE12345") == "ABCDE12345.app.mactivity")
    }

    @Test("File URL: nil without a team or a container, else Application Support in the container")
    func fileURL() {
        let container = URL(fileURLWithPath: "/Users/demo/Library/Group Containers/ABCDE12345.app.mactivity")
        #expect(WidgetFeed.fileURL(teamID: nil) { _ in container } == nil)
        #expect(WidgetFeed.fileURL(teamID: "ABCDE12345") { _ in nil } == nil)
        var asked: String?
        let url = WidgetFeed.fileURL(teamID: "ABCDE12345") { group in
            asked = group
            return container
        }
        #expect(asked == "ABCDE12345.app.mactivity")
        #expect(url?.path == container.path + "/Library/Application Support/widget-snapshot.json")
    }
}
