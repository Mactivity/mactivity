import Foundation
import Observation
import Startup

/// State for the Startup tab (expansion E4): the audit, the selection, and the one change it
/// can make (moving a user agent aside), which always waits for the user's confirmation.
@MainActor
@Observable
public final class StartupModel {
    public private(set) var items: [StartupItem] = []
    public private(set) var groups: [StartupGroup] = []
    public private(set) var summary = StartupSummary(items: [], macOSCount: 0)
    public private(set) var hasLoaded = false
    public private(set) var loadError: String?
    public var selection: StartupItem.ID?
    /// The item the Disable confirmation is asking about.
    public var pendingDisable: StartupItem?
    public private(set) var toast: String?

    @ObservationIgnored private var source: any StartupSource
    @ObservationIgnored private var toggle: any StartupItemToggling
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public init(source: any StartupSource, toggle: any StartupItemToggling) {
        self.source = source
        self.toggle = toggle
    }

    /// The real audit and the real `~/Library/LaunchAgents` mover.
    public static func live() -> StartupModel {
        StartupModel(source: LaunchdStartupSource(), toggle: UserLaunchAgentToggle.user)
    }

    /// Simulated items; Disable and Enable change only the simulation.
    public static func preview() -> StartupModel {
        let simulated = SimulatedStartupSource()
        return StartupModel(source: simulated, toggle: simulated)
    }

    /// Swaps simulated and real data together.
    /// Only rescans if the Startup tab has already loaded: the app sets the real source at every
    /// launch, and a scan nobody looks at is 20–55 ms plus the items kept in memory (D-062). The
    /// tab scans when it appears.
    public func replace(source: any StartupSource, toggle: any StartupItemToggling) {
        self.source = source
        self.toggle = toggle
        if hasLoaded {
            Task { await refresh() }
        }
    }

    public var selectedItem: StartupItem? {
        items.first { $0.id == selection }
    }

    public func refresh() async {
        let source = source
        do {
            async let found = source.items()
            async let macOS = source.macOSItemCount()
            let (items, count) = try await (found, macOS)
            apply(items, macOSCount: count)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    func apply(_ items: [StartupItem], macOSCount: Int) {
        self.items = items
        groups = StartupGroup.grouped(items)
        summary = StartupSummary(items: items, macOSCount: macOSCount)
        if let selection, !items.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    /// Shows the confirmation. Nothing moves until `confirmDisable()`.
    public func askToDisable(_ item: StartupItem) {
        guard item.canDisable else {
            return
        }
        pendingDisable = item
    }

    /// The user confirmed in the system dialog.
    public func confirmDisable() async {
        if let item = acceptDisable() {
            await disable(item)
        }
    }

    /// The user said yes: takes the pending item before the dialog's dismissal clears it.
    public func acceptDisable() -> StartupItem? {
        let item = pendingDisable
        pendingDisable = nil
        return item
    }

    /// Disables an accepted item (reversible: it moves to a folder Mactivity can move back from).
    public func disable(_ item: StartupItem) async {
        do {
            try await toggle.disable(item)
            show(toast: String(localized: "“\(item.name)” won't start at your next login.", bundle: .strings))
        } catch {
            show(toast: error.localizedDescription)
        }
        await refresh()
        selection = items.first { $0.label == item.label && $0.canEnable }?.id ?? selection
    }

    /// Moves a disabled agent back. Reversing Mactivity's own change needs no second confirmation.
    public func enable(_ item: StartupItem) async {
        guard item.canEnable else {
            return
        }
        do {
            try await toggle.enable(item)
            // Turned on here: not a new startup item to alert about (D-231).
            StartupWatch.acknowledge(item)
            show(toast: String(localized: "“\(item.name)” will start again at your next login.", bundle: .strings))
        } catch {
            show(toast: error.localizedDescription)
        }
        await refresh()
        selection = items.first { $0.label == item.label && $0.canDisable }?.id ?? selection
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.toast = nil
        }
    }
}

/// Words the view uses in more than one place.
enum StartupCopy {
    /// Followed by launchd's own key names, which stay in English.
    static let startedOnDemandBy = String(
        localized: "Started on demand by",
        bundle: .strings,
        comment: "Startup item detail label, then the launchd keys that start it on demand, verbatim (MachServices, Sockets, WatchPaths…)"
    )

    static let disableMessage = String(
        localized: """
        Mactivity moves its file to “\(UserLaunchAgentToggle.disabledFolderName)” in your Library folder. \
        It takes effect at your next login: if it's running now, it keeps running until then. \
        Nothing is deleted, and Enable puts it back.
        """,
        bundle: .strings,
        comment: "Disable confirmation message; the argument is a folder name, verbatim"
    )

    static let adminNote = String(
        localized: "This one is in a system folder and needs an administrator. Turn it off in Login Items & Extensions.",
        bundle: .strings
    )
    static let helperNote = String(
        localized: "The app registers this itself. Turn it off in the app or in Login Items & Extensions.",
        bundle: .strings
    )

    static func stateText(_ item: StartupItem) -> String {
        if !item.startsWithMac, item.state != .unknown {
            return String(
                localized: "startup.status.off",
                defaultValue: "Off",
                bundle: .strings,
                comment: "Startup item status: disabled, won't start at login"
            )
        }
        return StartupText.running(item)
    }

    static func evidence(_ owner: StartupOwner) -> String {
        switch owner.evidence {
        case .associatedBundleIdentifier: String(localized: "Named in the plist", bundle: .strings)
        case .executablePath: String(localized: "Runs from inside the app", bundle: .strings)
        case .containingApp: String(localized: "Ships inside the app", bundle: .strings)
        case .labelPrefix: String(localized: "Label matches the app's ID", bundle: .strings)
        case .missingApp: String(localized: "Its app is no longer installed", bundle: .strings)
        case .unknown: String(localized: "No app matched", bundle: .strings)
        }
    }
}
