import AppKit
import Core
import SwiftUI

/// Tabs in the menu bar window (spec 4.2).
enum CompactTab: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, disk, network, battery, projects

    var id: String {
        rawValue
    }

    var metricTab: MetricTab? {
        MetricTab(rawValue: rawValue)
    }

    var title: String {
        title(hasBattery: true)
    }

    func title(hasBattery: Bool) -> String {
        self == .projects ? SidebarItem.projects.title : metricTab?.title(hasBattery: hasBattery) ?? Self.overviewTitle
    }

    private static let overviewTitle = String(localized: "Overview", bundle: .strings)

    var symbol: String {
        symbol(hasBattery: true)
    }

    func symbol(hasBattery: Bool) -> String {
        self == .projects ? SidebarItem.projects.symbol : metricTab?.symbol(hasBattery: hasBattery) ?? SidebarItem.overview.symbol
    }

    var sidebarItem: SidebarItem {
        self == .projects ? .projects : metricTab?.sidebarItem ?? .overview
    }
}

#Preview("Menu bar window") {
    MenuBarContent(services: .preview(), isSimulated: .constant(true), mainWindowID: "main")
}
