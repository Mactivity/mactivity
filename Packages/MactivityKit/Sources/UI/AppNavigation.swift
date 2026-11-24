import Core
import Docker
import Foundation
import Observation
import Projects
import Simulated
import Storage

public enum StorageCleanupTarget: Sendable {
    case messages, backups
}

/// The History cards other places link to (D-196); the raw value is the card's scroll ID.
public enum HistorySection: String, Sendable {
    case crashes, sleep, accessories, temperature, updates, builds, flagged, launches
}

/// Where the main window is and what it highlights. Notifications deep-link through this.
@MainActor
@Observable
public final class AppNavigation {
    public var selection: SidebarItem = .overview {
        didSet {
            if selection != oldValue {
                remembers?.set(selection.rawValue, forKey: PreferenceKey.lastSidebarItem)
                if !isStepping {
                    backStack.append(oldValue)
                    backStack = Array(backStack.suffix(Self.historyLimit))
                    forwardStack.removeAll()
                }
                updateSteps()
            }
        }
    }

    /// Back and Forward between pages (D-195), like a browser: ⌘[ and ⌘] in the View menu.
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    @ObservationIgnored private var backStack: [SidebarItem] = []
    @ObservationIgnored private var forwardStack: [SidebarItem] = []
    @ObservationIgnored private var isStepping = false
    static let historyLimit = 50

    public func goBack() {
        guard let previous = backStack.popLast() else {
            return
        }
        forwardStack.append(selection)
        step(to: previous)
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else {
            return
        }
        backStack.append(selection)
        step(to: next)
    }

    private func step(to item: SidebarItem) {
        isStepping = true
        selection = item
        isStepping = false
        updateSteps()
    }

    private func updateSteps() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    /// Where the page is kept between launches; nil (tests, previews) keeps nothing.
    @ObservationIgnored private var remembers: UserDefaults?
    /// An app row to scroll to and pulse once. The list clears it after the pulse, so asking
    /// for the same app again pulses it again.
    public var highlightedAppID: AppIdentity.ID?
    /// Bumped to ask the always-alive menu bar label to open the main window.
    public private(set) var openMainWindowRequest = 0
    /// The row selected in a metric tab's app list: what the Process menu and the toolbar's Quit
    /// and Get Info act on.
    public var appListSelection: AppListSelection?
    /// The process the Get Info sheet shows.
    public var inspectedPID: Int32?
    /// A day for History to open on, scrolled to Your day (D-194). History clears it once shown.
    public var historyDay: Date?
    /// A History card to scroll to (D-196): where an alert or Checkup item about crashes, sleep,
    /// accessories or heat opens. History clears it once shown.
    public var historySection: HistorySection?
    /// A Storage cleanup to open (D-196): Checkup's Show for old Messages attachments or backups.
    /// Storage opens its sheet and clears it.
    public var storageCleanup: StorageCleanupTarget?
    /// The Alerts page's view: recent first, the rules a click away (D-238).
    public var alertsTab = AlertsTab.recent

    /// The Projects page's view: servers, space… (D-223); kept like the page itself.
    public var projectsTab = ProjectsTab.servers {
        didSet { remembers?.set(projectsTab.rawValue, forKey: PreferenceKey.lastProjectsTab) }
    }

    public init() {}

    /// Reopens on the page that was showing when Mactivity last quit, whether the person quit or
    /// an update relaunched it, and keeps the page from now on.
    public func remember(in defaults: UserDefaults) {
        if let saved = defaults.string(forKey: PreferenceKey.lastSidebarItem).flatMap(SidebarItem.init(rawValue:)) {
            selection = saved
        }
        if let tab = defaults.string(forKey: PreferenceKey.lastProjectsTab).flatMap(ProjectsTab.init(rawValue:)) {
            projectsTab = tab
        }
        // Reopening on the last page isn't a step anyone took: nothing to go back to yet.
        backStack.removeAll()
        updateSteps()
        remembers = defaults
    }

    /// Opens the main window where it was (a Dock click with the window closed).
    public func openMainWindow() {
        openMainWindowRequest += 1
    }

    /// Storage with one of its cleanups open (D-196).
    public func showCleanup(_ cleanup: StorageCleanupTarget) {
        storageCleanup = cleanup
        show(.storage)
    }

    /// History, scrolled to one of its cards (D-196).
    public func showHistory(_ section: HistorySection) {
        historySection = section
        show(.history)
    }

    /// An alert's page: its History card for crashes, sleep, accessories and heat, otherwise its
    /// tab with the app highlighted.
    public func show(_ rule: AlertRule, app: AppIdentity.ID?) {
        if let section = rule.historySection {
            showHistory(section)
        } else {
            show(rule.sidebarItem, highlighting: app)
        }
    }

    /// History, scrolled to Your day for `day` (D-194).
    public func showDay(_ day: Date) {
        historyDay = day
        show(.history)
    }

    /// Opens the main window on a tab, optionally highlighting an app (spec 4.4).
    public func show(_ item: SidebarItem, highlighting appID: AppIdentity.ID? = nil) {
        selection = item
        highlightedAppID = appID
        openMainWindowRequest += 1
    }
}

// The privileged helper's state as Settings shows it (spec 4.5, 6.9).
