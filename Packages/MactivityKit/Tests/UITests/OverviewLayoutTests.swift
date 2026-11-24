import Testing
@testable import UI

/// Overview's tiles, moved and hidden by the person (D-241).
struct OverviewLayoutTests {
    @Test("A tile dropped on another takes its place, either way")
    func moving() {
        let layout = OverviewLayout.standard
        #expect(layout.moving(.battery, onto: .cpu).order.prefix(3) == [.battery, .cpu, .gpu])
        let down = layout.moving(.cpu, onto: .disk).order
        #expect(Array(down.prefix(4)) == [.gpu, .memory, .disk, .cpu])
        let same = layout.moving(.cpu, onto: .cpu)
        #expect(same.order == layout.order)
    }

    @Test("Saved and read back; unknown names dropped, new tiles added in their place")
    func storage() throws {
        let layout = OverviewLayout.standard.moving(.today, onto: .cpu).showing(.gpu, false)
        #expect(OverviewLayout(rawValue: layout.rawValue) == layout)
        let old = #"{"order":["today","cpu","sparkline","memory"],"hidden":["gpu","nope"]}"#
        let read = try #require(OverviewLayout(rawValue: old))
        #expect(Set(read.order) == Set(OverviewTile.allCases))
        #expect(read.order.count == OverviewTile.allCases.count)
        #expect(Array(read.order.prefix(3)) == [.today, .cpu, .gpu])
        #expect(read.hidden == [.gpu])
        #expect(OverviewLayout(rawValue: "not json") == nil)
    }

    @Test("Side-by-side tiles share runs; wide ones stand alone; hidden ones are gone")
    func runs() {
        let layout = OverviewLayout.standard.moving(.today, onto: .disk).showing(.unusual, false)
        let runs = OverviewLayout.runs(layout.visible)
        #expect(runs == [[.cpu, .gpu, .memory], [.today], [.disk, .network, .battery], [.memoryByType, .memoryByApp, .powerByApp]])
    }

    @Test("Columns fill rows when they can, and show at most three when they can't")
    func columns() {
        #expect(OverviewView.columnCount(width: 900, items: 9) == 3)
        #expect(OverviewView.columnCount(width: 900, items: 7) == 3)
        #expect(OverviewView.columnCount(width: 400, items: 7) == 1)
        #expect(OverviewView.columnCount(width: 900, items: 1) == 1)
        #expect(OverviewView.columnCount(width: 900, items: 8) == 3)
        #expect(OverviewView.columnCount(width: 900, items: 6) == 3)
        #expect(OverviewView.columnCount(width: 1700, items: 6) == 6)
        #expect(OverviewView.columnCount(width: 1150, items: 6) == 3)
        #expect(OverviewView.columnCount(width: 900, items: 5) == 3)
    }

    @Test("Equal layouts are equal, however their JSON comes out")
    func equality() {
        for _ in 0 ..< 50 {
            #expect(OverviewLayout.standard.showing(.gpu, false) == OverviewLayout.standard.showing(.gpu, false))
            #expect(CompactLayout.standard.showing(.today, false) == CompactLayout.standard.showing(.today, false))
        }
        #expect(OverviewLayout.standard.isStandard)
    }

    @Test("A tile put at a place among the others (D-242)")
    func toIndex() {
        let layout = OverviewLayout.standard
        #expect(Array(layout.moving(.battery, toIndex: 0).order.prefix(2)) == [.battery, .cpu])
        #expect(layout.moving(.cpu, toIndex: 99).order.last == .cpu)
        let same = layout.moving(.cpu, toIndex: 0)
        #expect(same.order == layout.order)
    }
}
