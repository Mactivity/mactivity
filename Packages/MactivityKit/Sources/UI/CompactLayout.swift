import SwiftUI

/// A part of the menu bar window's Overview (D-241).
public enum CompactSection: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The rows: uptime, one per metric, temperature.
    case figures
    case busiest
    case today

    public var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .figures: String(localized: "Figures", bundle: .strings, comment: "Menu bar window section: one row per metric")
        case .busiest: String(localized: "Busiest right now", bundle: .strings)
        case .today: String(localized: "Today so far", bundle: .strings, comment: "Overview card: the day so far")
        }
    }
}

/// The menu bar window's Overview as the person arranged it (D-241): the rows' order, and the
/// sections' order and which are off. Which rows are off stays in `overviewHiddenRows`, as
/// before. Stored as JSON in the app's defaults.
public struct CompactLayout: Equatable, Sendable, RawRepresentable {
    public var rows: [OverviewRow]
    public var sections: [CompactSection]
    public var hiddenSections: Set<CompactSection>

    public static let standard = CompactLayout(rows: OverviewRow.allCases, sections: CompactSection.allCases, hiddenSections: [])

    public init(rows: [OverviewRow], sections: [CompactSection], hiddenSections: Set<CompactSection>) {
        self.rows = rows
        self.sections = sections
        self.hiddenSections = hiddenSections
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        self = CompactLayout(
            rows: Self.complete(stored.rows.compactMap(OverviewRow.init(rawValue:)), all: OverviewRow.allCases),
            sections: Self.complete(stored.sections.compactMap(CompactSection.init(rawValue:)), all: CompactSection.allCases),
            hiddenSections: Set(stored.hiddenSections.compactMap(CompactSection.init(rawValue:)))
        )
    }

    public var rawValue: String {
        let stored = Stored(
            rows: rows.map(\.rawValue), sections: sections.map(\.rawValue), hiddenSections: hiddenSections.map(\.rawValue).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private struct Stored: Codable {
        let rows: [String]
        let sections: [String]
        let hiddenSections: [String]
    }

    /// Every case once: duplicates dropped, missing ones after the case before them in `all`.
    static func complete<T: Equatable>(_ order: [T], all: [T]) -> [T] {
        var result: [T] = []
        for item in order where !result.contains(item) {
            result.append(item)
        }
        for (index, item) in all.enumerated() where !result.contains(item) {
            let before = all[..<index].last { result.contains($0) }
            let position = before.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(item, at: position)
        }
        return result
    }

    public var isStandard: Bool {
        self == .standard
    }

    public var visibleSections: [CompactSection] {
        sections.filter { !hiddenSections.contains($0) }
    }

    /// `row` dropped on `target`: it takes the target's place.
    public func moving(_ row: OverviewRow, onto target: OverviewRow) -> CompactLayout {
        var copy = self
        copy.rows = Self.move(row, onto: target, in: rows)
        return copy
    }

    /// `row` put at `index` among the `shown` rows without it; the hidden ones keep their places
    /// relative to the rest.
    public func moving(_ row: OverviewRow, toIndex index: Int, among shown: [OverviewRow]) -> CompactLayout {
        let others = shown.filter { $0 != row }
        var copy = self
        copy.rows.removeAll { $0 == row }
        if index < others.count, let before = copy.rows.firstIndex(of: others[index]) {
            copy.rows.insert(row, at: before)
        } else if let last = others.last, let after = copy.rows.firstIndex(of: last) {
            copy.rows.insert(row, at: after + 1)
        } else {
            copy.rows.append(row)
        }
        return copy
    }

    public func movingRows(fromOffsets source: IndexSet, toOffset destination: Int) -> CompactLayout {
        var copy = self
        copy.rows.move(fromOffsets: source, toOffset: destination)
        return copy
    }

    public func rowToTop(_ row: OverviewRow) -> CompactLayout {
        var copy = self
        copy.rows = [row] + rows.filter { $0 != row }
        return copy
    }

    /// One place earlier (`by: -1`) or later (`by: 1`); nothing at either end.
    public func moving(_ section: CompactSection, by offset: Int) -> CompactLayout {
        guard let index = sections.firstIndex(of: section), sections.indices.contains(index + offset) else {
            return self
        }
        var copy = self
        copy.sections.swapAt(index, index + offset)
        return copy
    }

    public func movingSections(fromOffsets source: IndexSet, toOffset destination: Int) -> CompactLayout {
        var copy = self
        copy.sections.move(fromOffsets: source, toOffset: destination)
        return copy
    }

    public func showing(_ section: CompactSection, _ shown: Bool) -> CompactLayout {
        var copy = self
        if shown {
            copy.hiddenSections.remove(section)
        } else {
            copy.hiddenSections.insert(section)
        }
        return copy
    }

    static func move<T: Equatable>(_ item: T, onto target: T, in order: [T]) -> [T] {
        guard item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else {
            return order
        }
        var order = order
        order.remove(at: from)
        order.insert(item, at: to)
        return order
    }
}
