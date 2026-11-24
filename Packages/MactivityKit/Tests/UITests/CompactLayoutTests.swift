import Testing
@testable import UI

/// The menu bar window's Overview, arranged by the person (D-241).
@MainActor
struct CompactLayoutTests {
    @Test("Rows move onto each other and to the top; the shown rows follow the order")
    func rows() {
        let layout = CompactLayout.standard.moving(.temperature, onto: .cpu)
        #expect(Array(layout.rows.prefix(3)) == [.uptime, .temperature, .cpu])
        #expect(layout.rowToTop(.network).rows.first == .network)
        let shown = CompactOverview.rows(FigureFixture.snapshot(), hidden: [.uptime], choices: .automatic, order: layout.rows).map(\.row)
        #expect(shown.first == .temperature)
        #expect(!shown.contains(.uptime))
    }

    @Test("Sections move a place at a time and hide; nothing past either end")
    func sections() {
        let layout = CompactLayout.standard
        #expect(layout.moving(.today, by: -1).sections == [.figures, .today, .busiest])
        let unmoved = layout.moving(.figures, by: -1)
        #expect(unmoved.sections == layout.sections)
        #expect(layout.showing(.busiest, false).visibleSections == [.figures, .today])
    }

    @Test("Saved and read back; unknown names dropped, new ones added")
    func storage() throws {
        let layout = CompactLayout.standard.moving(.gpu, onto: .uptime).showing(.today, false)
        let read = try #require(CompactLayout(rawValue: layout.rawValue))
        #expect(read.rows == layout.rows)
        #expect(read.hiddenSections == [.today])
        let old = try #require(CompactLayout(rawValue: #"{"rows":["gpu","fans"],"sections":["today"],"hiddenSections":["x"]}"#))
        // A row the stored order lacks comes in after the one before it in the standard order.
        #expect(Array(old.rows.prefix(3)) == [.uptime, .cpu, .gpu])
        #expect(Set(old.rows) == Set(OverviewRow.allCases))
        #expect(old.sections == [.figures, .busiest, .today])
        #expect(old.hiddenSections.isEmpty)
    }

    @Test("A row put at a place among the shown rows keeps hidden ones where they were (D-242)")
    func toIndexAmongShown() {
        let shown: [OverviewRow] = [.cpu, .memory, .network]
        let layout = CompactLayout.standard.moving(.network, toIndex: 0, among: shown)
        #expect(Array(layout.rows.prefix(4)) == [.uptime, .network, .cpu, .gpu])
        let last = CompactLayout.standard.moving(.cpu, toIndex: 2, among: shown)
        #expect(last.rows.firstIndex(of: .cpu) == (last.rows.firstIndex(of: .network) ?? 0) + 1)
    }
}
