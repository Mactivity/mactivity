import SwiftUI

/// Tables as tall as their rows (D-239): a short list ends where its rows do, rather than
/// stretching to the window with empty stripes. Past the room there is, the table scrolls as
/// before. Heights are what macOS 26 draws for an inset table, as measured for Containers.
enum TableFit {
    static let oneLineRow: CGFloat = 26
    static let twoLineRow = ContainerLayout.rowHeight
    static let sectionHeader: CGFloat = 46
    static let columnHeader = ContainerLayout.columnHeaderHeight
    /// The shortest a table gets in a short window: its header and about two rows.
    static let minimum = ContainerLayout.minTableHeight

    static func height(rows: CGFloat, sections: Int = 0) -> CGFloat {
        columnHeader + CGFloat(sections) * sectionHeader + rows + Tokens.Spacing.s
    }

    static func height(twoLineRows count: Int) -> CGFloat {
        height(rows: CGFloat(count) * twoLineRow)
    }
}

extension View {
    /// Never taller than `height`; shorter, and scrolling, when the window is.
    func fittedTable(_ height: CGFloat) -> some View {
        frame(minHeight: min(TableFit.minimum, height), maxHeight: height)
    }
}
