import Core
import SwiftUI

/// One of Overview's tiles (D-241).
public enum OverviewTile: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery
    case memoryByType, memoryByApp, powerByApp
    case unusual, today

    public var id: String {
        rawValue
    }

    /// Wide tiles take the page's width; the others share a row.
    var isWide: Bool {
        self == .unusual || self == .today
    }

    var isDonut: Bool {
        self == .memoryByType || self == .memoryByApp || self == .powerByApp
    }

    var metric: MetricTab? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .battery: .battery
        default: nil
        }
    }

    func title(hasBattery: Bool) -> String {
        if let metric {
            return metric.title(hasBattery: hasBattery)
        }
        return switch self {
        case .memoryByType: String(localized: "Memory by type", bundle: .strings, comment: "Overview card")
        case .memoryByApp: String(localized: "Memory by app", bundle: .strings, comment: "Overview card")
        case .powerByApp: String(localized: "Power by app", bundle: .strings, comment: "Overview card")
        case .unusual: String(localized: "Out of the ordinary", bundle: .strings, comment: "Overview card: apps doing more than usual")
        default: String(localized: "Today so far", bundle: .strings, comment: "Overview card: the day so far")
        }
    }

    var symbol: String {
        if let metric {
            return metric.sidebarItem.symbol
        }
        return switch self {
        case .memoryByType: SidebarItem.memory.symbol
        case .memoryByApp: Tokens.Symbols.apps
        case .powerByApp: "bolt"
        case .unusual: "sparkle.magnifyingglass"
        default: "clock.arrow.circlepath"
        }
    }
}

/// Overview's tiles in the order the person put them, and the ones they hid (D-241). Stored as
/// JSON in the app's defaults.
public struct OverviewLayout: Codable, Equatable, Sendable, RawRepresentable {
    public var order: [OverviewTile]
    public var hidden: Set<OverviewTile>

    public static let standard = OverviewLayout(order: OverviewTile.allCases, hidden: [])

    public init(order: [OverviewTile], hidden: Set<OverviewTile>) {
        self.order = order
        self.hidden = hidden
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        // Names a later version dropped are skipped; tiles it added come in at their place.
        let known = decoded.order.compactMap(OverviewTile.init(rawValue:))
        self = OverviewLayout(order: known, hidden: Set(decoded.hidden.compactMap(OverviewTile.init(rawValue:)))).normalized()
    }

    public var rawValue: String {
        let stored = Stored(order: order.map(\.rawValue), hidden: hidden.map(\.rawValue).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private struct Stored: Codable {
        let order: [String]
        let hidden: [String]
    }

    /// Every tile once: duplicates dropped, missing ones after the tile that comes before them
    /// in the standard order.
    public func normalized() -> OverviewLayout {
        var seen = Set<OverviewTile>()
        var result = order.filter { seen.insert($0).inserted }
        for (index, tile) in OverviewTile.allCases.enumerated() where !seen.contains(tile) {
            let before = OverviewTile.allCases[..<index].last { result.contains($0) }
            let position = before.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(tile, at: position)
        }
        return OverviewLayout(order: result, hidden: hidden)
    }

    public var visible: [OverviewTile] {
        order.filter { !hidden.contains($0) }
    }

    public var isStandard: Bool {
        self == .standard
    }

    /// `tile` dropped on `target`: it takes the target's place, and the target moves along.
    public func moving(_ tile: OverviewTile, onto target: OverviewTile) -> OverviewLayout {
        guard tile != target, let from = order.firstIndex(of: tile), let to = order.firstIndex(of: target) else {
            return self
        }
        var order = order
        order.remove(at: from)
        order.insert(tile, at: to)
        return OverviewLayout(order: order, hidden: hidden)
    }

    /// `tile` taken out and put back at `index` among the others.
    public func moving(_ tile: OverviewTile, toIndex index: Int) -> OverviewLayout {
        var order = order.filter { $0 != tile }
        order.insert(tile, at: min(max(index, 0), order.count))
        return OverviewLayout(order: order, hidden: hidden)
    }

    public func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> OverviewLayout {
        var order = order
        order.move(fromOffsets: source, toOffset: destination)
        return OverviewLayout(order: order, hidden: hidden)
    }

    public func showing(_ tile: OverviewTile, _ shown: Bool) -> OverviewLayout {
        var hidden = hidden
        if shown {
            hidden.remove(tile)
        } else {
            hidden.insert(tile)
        }
        return OverviewLayout(order: order, hidden: hidden)
    }

    public func toTop(_ tile: OverviewTile) -> OverviewLayout {
        var order = order.filter { $0 != tile }
        order.insert(tile, at: 0)
        return OverviewLayout(order: order, hidden: hidden)
    }

    /// Tiles in runs: headline cards together and donuts together, as they always sat, and each
    /// wide tile on its own.
    public static func runs(_ tiles: [OverviewTile]) -> [[OverviewTile]] {
        var runs: [[OverviewTile]] = []
        for tile in tiles {
            if tile.isWide || runs.last?.first?.isWide != false || runs.last?.first?.isDonut != tile.isDonut {
                runs.append([tile])
            } else {
                runs[runs.count - 1].append(tile)
            }
        }
        return runs
    }
}
