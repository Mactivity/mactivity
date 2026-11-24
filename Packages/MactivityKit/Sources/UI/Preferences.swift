import Core
import Foundation
import SwiftUI

/// Launch arguments the scripts pass, read once.
public enum LaunchOverrides {
    /// `-MeasureScreenshotMode YES` (scripts/site-shots.sh), always with simulated data. Full
    /// sparklines and thirty days of history, so the website's screenshots don't show an app that
    /// just started; a Storage map instead of the empty state; and no "Simulated data" subtitle,
    /// since the site says so once.
    public static let isScreenshotMode = UserDefaults.standard.bool(forKey: "MeasureScreenshotMode")
    /// `-MeasureDemoTour YES` (scripts/demo-video.sh): the main window tours the tabs, then quits.
    public static let isDemoTour = UserDefaults.standard.bool(forKey: "MeasureDemoTour")
}

/// UserDefaults keys. The app and the views read the same keys through `@AppStorage`.
public enum PreferenceKey {
    /// Settings → General → Keyboard Shortcuts (1.6): each action's shortcut, as JSON.
    public static let keyShortcuts = "keyShortcuts"
    /// Settings → Alerts: hold notifications while presenting or on a call (1.6). On by default.
    public static let holdsAlertsWhilePresenting = "holdsAlertsWhilePresenting"
    /// Overview's tiles: their order and the hidden ones (D-241).
    public static let overviewLayout = "overviewLayout"
    /// The menu bar window's Overview: the rows' order, and the sections' order and which are off (D-241).
    public static let compactLayout = "compactLayout"
    /// Settings → Customize (D-240).
    public static let metricPalette = "metricPalette"
    public static let figureTypeface = "figureTypeface"
    public static let figureWeight = "figureWeight"
    public static let cardDensity = "cardDensity"
    public static let simulatedData = "simulatedData"
    public static let menuBarMode = "menuBarMode"
    public static let menuBarMetric = "menuBarMetric"
    public static let menuBarStackedMetrics = "menuBarStackedMetrics"
    /// The pulse glyph before a figure, graph, or stacked display. On by default.
    public static let menuBarShowsGlyph = "menuBarShowsGlyph"
    /// Graph mode also shows the current figure after the bars. On by default.
    public static let menuBarGraphShowsValue = "menuBarGraphShowsValue"
    /// The Settings tab last shown, so "Customize…" in the menu bar window can open Menu Bar.
    public static let settingsTab = "settingsTab"
    public static let appearance = "appearance"
    public static let alertSettings = "alertSettings"
    public static let historyRetentionDays = "historyRetentionDays"
    /// Settings → History: record which app is in front (D-098). On unless turned off.
    public static let recordsTimeInFront = "recordsTimeInFront"
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
    public static let showsWindowAtLaunch = "showsWindowAtLaunch"
    /// Per-app volume (M10) is experimental and off by default (docs/spikes/M10-per-app-volume.md).
    public static let perAppVolume = "perAppVolume"
    /// The "while you were away" digest (E2), off by default.
    public static let dailyDigest = "dailyDigest"
    public static let lastDigestSent = "lastDigestSent"
    /// The weekly summary (D-102). On unless turned off.
    public static let weeklyDigest = "weeklyDigest"
    /// Which day it goes out (`WeeklySummaryDay`, D-273), and when that last changed.
    public static let weeklyDigestDay = "weeklyDigestDay"
    public static let weeklyDigestDayChanged = "weeklyDigestDayChanged"
    /// Settings → Customize: Standard or Larger figures (D-276).
    public static let figureSize = "figureSize"
    public static let lastWeeklyDigestSent = "lastWeeklyDigestSent"
    /// History strips show each top app's change against the previous period (expansion E3).
    public static let historyComparesPrevious = "historyComparesPrevious"
    /// Seconds between samples while a window is open: 1 (default), 2, or 5 (D-065).
    public static let visibleIntervalSeconds = "visibleIntervalSeconds"
    /// What each metric's figure shows (`FigureChoices`), in the menu bar, its window, and the
    /// cards. Missing means Automatic: each place's usual figure.
    public static let memoryFigure = "memoryFigure"
    public static let networkFigure = "networkFigure"
    public static let diskFigure = "diskFigure"
    public static let batteryFigure = "batteryFigure"
    public static let temperatureFigure = "temperatureFigure"
    /// Overview rows turned off in the menu bar window (`OverviewRow.encodeHidden`). Empty: all on.
    public static let overviewHiddenRows = "overviewHiddenRows"
    /// Storage's Full Disk Access explainer, once closed, stays closed.
    public static let fullDiskAccessExplainerDismissed = "storage.fullDiskAccessExplainerDismissed"
    /// Storage's Space you can get back card is open (D-121).
    public static let reclaimableExpanded = "storage.reclaimableExpanded"
    public static let photosLibraryExpanded = "storage.photosLibraryExpanded"
    /// The main window's page, reopened at the next launch.
    public static let lastSidebarItem = "navigation.lastSidebarItem"
    /// Where the main window was last, as `NSWindow.frameDescriptor` (D-270).
    public static let mainWindowFrame = "navigation.mainWindowFrame"
    public static let lastProjectsTab = "navigation.lastProjectsTab"
    /// The monthly data budget, JSON (D-235).
    public static let dataBudget = "network.dataBudget"
    /// Check Homebrew packages for known vulnerabilities (`brew vulns`, OSV.dev). Off by default:
    /// an opt-in, Settings → Privacy (D-252).
    public static let checksVulnerabilities = "privacy.checksVulnerabilities"
    /// The last vulnerability check, JSON, so a relaunch doesn't check again (D-252).
    public static let vulnerabilityScan = "software.vulnerabilityScan"
    /// The old Quick Search switch (D-137): read once, for the first shortcuts (1.6).
    public static let quickSearchShortcut = "quickSearch.shortcut"
    /// Stay Awake keeps the display on too (D-197).
    public static let keepAwakeDisplay = "keepAwake.display"
    /// Ask Mactivity in Quick Search (D-153). Off by default: an opt-in (D-161).
    public static let askMactivity = "ask.enabled"
}

/// Menu bar display modes (spec 4.1). Icon is the default: it redraws only when strain changes,
/// which is what keeps idle cost inside the budget (D-019, D-020).
public enum MenuBarMode: String, CaseIterable, Identifiable, Sendable {
    case icon, figure, graph, stacked

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .icon: String(localized: "Icon", bundle: .strings, comment: "Menu bar mode: just the Mactivity symbol")
        case .figure: String(localized: "Figure", bundle: .strings, comment: "Menu bar mode: one metric's figure")
        case .graph: String(localized: "Graph", bundle: .strings, comment: "Menu bar mode: a small bar graph")
        case .stacked: String(localized: "Stacked", bundle: .strings, comment: "Menu bar mode: several metrics side by side")
        }
    }

    /// How often the item changes (spec 6.13, D-051).
    public var refreshNote: String {
        switch self {
        case .icon: String(localized: "Changes only when your Mac is under strain. The lightest option.", bundle: .strings)
        case .figure, .graph, .stacked:
            // As Settings → General says it, and as the item behaves: it redraws on a real change
            // (D-068), at least once a minute (D-197).
            String(
                localized: """
                With no window open, checks every 10 seconds and redraws when a figure changes noticeably, at least once a \
                minute. With a window open, it follows Update while a window is open in General.
                """,
                bundle: .strings
            )
        }
    }

    /// Mactivity's whole idle CPU in this mode, as a percentage of one core: Release build, menu
    /// bar only (`make measure MENUBAR=<mode>`, 2026-09-26), after D-068's redraw filter and
    /// D-069's AppKit drawing. Icon 0.083–0.097; stacked (two columns) 0.103; figure 0.175; graph
    /// 0.207 and 0.280. Runs on a busy Mac vary by several hundredths. The difference from the
    /// icon is the status item's redraw, about 35 ms per change (D-019).
    public var measuredIdleCPU: Double {
        switch self {
        case .icon: 0.09
        case .figure: 0.18
        case .graph: 0.24
        case .stacked: 0.10
        }
    }

    /// One line for Settings: what this mode costs against the icon, which never redraws.
    public var idleCostNote: String? {
        guard self != .icon else {
            return nil
        }
        let mode = Formatters.percent(measuredIdleCPU, fractionDigits: 2)
        let icon = Formatters.percent(Self.icon.measuredIdleCPU, fractionDigits: 2)
        return String(
            localized: "Idle cost: about \(mode) of one core, against \(icon) for the icon.", bundle: .strings,
            comment: "Menu bar mode's idle CPU, e.g. 0.18%, against the icon mode's"
        )
    }
}

/// Metrics the menu bar can show (spec 4.1).
public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, network, temperature, battery

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .cpu: Words.cpu
        case .memory: Words.memory
        case .gpu: Words.gpu
        case .network: Words.network
        case .temperature: Words.temperature
        case .battery: Words.battery
        }
    }

    /// Three-letter label for stacked mode.
    public var shortTitle: String {
        switch self {
        case .cpu: Words.cpuShort
        case .memory: Words.memoryShort
        case .gpu: Words.gpuShort
        case .network: Words.networkShort
        case .temperature: Words.temperatureShort
        case .battery: Words.batteryShort
        }
    }

    /// Looked up once: the menu bar draws and measures these on every update.
    private enum Words {
        static let cpu = String(localized: "CPU", bundle: .strings, comment: "Sidebar item and tab title; also a metric's name in settings")
        static let memory = String(localized: "Memory", bundle: .strings)
        static let gpu = String(localized: "GPU", bundle: .strings)
        static let network = String(localized: "Network", bundle: .strings)
        static let temperature = String(localized: "Temperature", bundle: .strings)
        static let battery = String(localized: "Battery", bundle: .strings)
        static let cpuShort = String(
            localized: "menubar.cpu", defaultValue: "CPU", bundle: .strings,
            comment: "Menu bar label for the CPU column, next to MEM and NET; keep it to about 3 letters"
        )
        static let gpuShort = String(
            localized: "menubar.gpu", defaultValue: "GPU", bundle: .strings,
            comment: "Menu bar label for the GPU column, next to MEM and NET; keep it to about 3 letters"
        )
        static let memoryShort = String(
            localized: "MEM", bundle: .strings, comment: "Menu bar abbreviation of Memory; keep it to about 3 letters"
        )
        static let networkShort = String(
            localized: "NET", bundle: .strings, comment: "Menu bar abbreviation of Network; keep it to about 3 letters"
        )
        static let temperatureShort = String(
            localized: "TMP", bundle: .strings, comment: "Menu bar abbreviation of Temperature; keep it to about 3 letters"
        )
        static let batteryShort = String(
            localized: "BAT", bundle: .strings, comment: "Menu bar abbreviation of Battery; keep it to about 3 letters"
        )
    }

    var tab: MetricTab {
        switch self {
        case .cpu, .temperature: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .network: .network
        case .battery: .battery
        }
    }

    /// Graph mode has no temperature history yet (E8); it draws CPU load instead.
    public var graphSource: MenuBarMetric {
        self == .temperature ? .cpu : self
    }

    /// Graph mode has no temperature history to draw.
    public static var graphable: [MenuBarMetric] {
        allCases.filter { $0 != .temperature }
    }

    /// Stacked mode shows up to four columns, like the reference.
    public static let stackedLimit = 4
    /// What stacked mode shows until the user picks.
    public static let stackedDefault = "cpu,memory"

    /// "cpu,memory" ↔ [.cpu, .memory], for `@AppStorage`. Unknown names and repeats are dropped,
    /// and at most `stackedLimit` are kept.
    public static func decodeList(_ raw: String) -> [MenuBarMetric] {
        var seen: [MenuBarMetric] = []
        for metric in raw.split(separator: ",").compactMap({ MenuBarMetric(rawValue: String($0)) }) where !seen.contains(metric) {
            seen.append(metric)
        }
        return Array(seen.prefix(stackedLimit))
    }

    public static func encodeList(_ metrics: [MenuBarMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// The stacked checklist: turning a metric on or off keeps the list in `allCases` order, never
    /// lets it pass `stackedLimit` (turning on a fifth is ignored), and never empties it.
    public static func toggling(_ metric: MenuBarMetric, on isOn: Bool, in list: [MenuBarMetric]) -> [MenuBarMetric] {
        if isOn, !list.contains(metric), list.count >= stackedLimit {
            return list
        }
        let wanted = isOn ? list + [metric] : list.filter { $0 != metric }
        let ordered = allCases.filter(wanted.contains)
        return ordered.isEmpty ? list : ordered
    }
}

/// Settings panes, remembered across openings. "Customize Menu Bar…" opens `menuBar`.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, customize, menuBar, alerts, history, helper, privacy
}

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .system: String(
                localized: "appearance.system", defaultValue: "System", bundle: .strings,
                comment: "Appearance: follow the system's light or dark mode"
            )
        case .light: String(localized: "Light", bundle: .strings, comment: "Appearance")
        case .dark: String(localized: "Dark", bundle: .strings, comment: "Appearance")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension AlertSettings {
    /// JSON for `@AppStorage`. Falls back to the defaults when missing or unreadable.
    public static func decode(_ raw: String) -> AlertSettings {
        guard let data = raw.data(using: .utf8), let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }
}
