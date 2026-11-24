import AppKit
import Core
import Foundation

/// Quit and Force Quit from app and process rows (spec 5.8). Everything goes through
/// `ConfirmedAction` (CLAUDE.md rule 4); this only words the question and reports the answer.
@MainActor
extension AppServices {
    /// Whether a row can be quit without the helper (M9).
    public func canTerminate(_ app: AppIdentity) -> Bool {
        guard app.kind != .system else {
            return false
        }
        guard let bundleID = app.bundleID, let own = Bundle.main.bundleIdentifier else {
            return true
        }
        return bundleID != own
    }

    public func requestQuit(
        _ app: AppAggregate, pids: [Int32], mode: TerminationMode, presenter: ConfirmedAction.Presenter = .window
    ) {
        guard canTerminate(app.app) else {
            return
        }
        let count = app.processCount
        let name = app.app.name
        let isForce = mode == .forceQuit
        confirmedAction.ask(ConfirmedAction.Request(
            title: isForce
                ? String(localized: "Force Quit \(name)?", bundle: .strings, comment: "Confirmation title; %@ is an app's name")
                : String(localized: "Quit \(name)?", bundle: .strings, comment: "Confirmation title; %@ is an app's name"),
            message: isForce
                ? String(localized: "\(count) processes will close immediately. Unsaved changes will be lost.", bundle: .strings)
                : String(localized: "\(count) processes will close. \(name) may ask to save changes first.", bundle: .strings),
            confirmTitle: Self.confirmTitle(mode),
            targets: [.app(app.app.id, pids: pids)],
            mode: mode,
            presenter: presenter
        ) { [weak self] results in
            self?.report(results, name: name, mode: mode)
        })
    }

    public func requestQuit(_ process: ProcessSample, mode: TerminationMode, presenter: ConfirmedAction.Presenter = .window) {
        // Never macOS's own processes, nor Mactivity itself, from any entry point: the app list
        // already refused them, Quick Search's ⌘⌫ didn't (D-142).
        guard process.app != AppIdentity.system.id, process.pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        let name = process.name
        let pid = process.pid
        // A string, so the PID isn't grouped like a count ("8,274").
        let pidText = String(pid)
        let isForce = mode == .forceQuit
        confirmedAction.ask(ConfirmedAction.Request(
            title: isForce
                ? String(
                    localized: "Force Quit “\(name)” (PID \(pidText))?", bundle: .strings,
                    comment: "Confirmation title; a process name and its ID"
                )
                : String(
                    localized: "Quit “\(name)” (PID \(pidText))?", bundle: .strings,
                    comment: "Confirmation title; a process name and its ID"
                ),
            message: isForce
                ? String(localized: "It stops immediately, without a chance to clean up.", bundle: .strings)
                : String(localized: "It's asked to exit, and stopped after 5 seconds if it doesn't.", bundle: .strings),
            confirmTitle: Self.confirmTitle(mode),
            targets: [.process(pid)],
            mode: mode,
            presenter: presenter
        ) { [weak self] results in
            self?.report(
                results, name: String(localized: "“\(name)”", bundle: .strings, comment: "A process's name, quoted"), mode: mode
            )
        })
    }

    private static func confirmTitle(_ mode: TerminationMode) -> String {
        mode == .forceQuit
            ? String(localized: "Force Quit", bundle: .strings, comment: "Confirmation button")
            : String(localized: "Quit", bundle: .strings, comment: "Confirmation button")
    }

    private func report(_ results: [TerminationResult], name: String, mode: TerminationMode) {
        let survivors = results.flatMap(\.survivors)
        let stopped = results.flatMap(\.terminated)
        if results.isEmpty {
            show(toast: String(
                localized: "Couldn't stop \(name). It may belong to macOS or another user.", bundle: .strings
            ))
        } else if survivors.isEmpty {
            show(toast: mode == .forceQuit
                ? String(localized: "\(name) was force quit.", bundle: .strings, comment: "%@ is an app or a quoted process name")
                : String(localized: "\(name) quit.", bundle: .strings, comment: "%@ is an app or a quoted process name"))
        } else if stopped.isEmpty, mode == .quit {
            show(toast: String(
                localized: "\(name) is still open. It may be asking to save, or it belongs to another user.", bundle: .strings
            ))
        } else {
            let count = survivors.count
            show(toast: String(localized: "\(name) stopped, but \(count) processes are still running.", bundle: .strings))
        }
    }

    /// Reveals an app bundle in Finder.
    public func showInFinder(_ app: AppIdentity) {
        guard app.kind == .app || app.kind == .terminal, FileManager.default.fileExists(atPath: app.iconKey) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.iconKey)])
    }
}

/// A row in a metric tab's app list: an app, or one of its processes. Carries the app so the
/// Process menu can tell what applies without looking the row up.
public enum AppListSelection: Hashable, Sendable {
    case app(AppIdentity.ID)
    case process(pid: Int32, app: AppIdentity.ID)

    var appID: AppIdentity.ID {
        switch self {
        case let .app(id), let .process(_, id): id
        }
    }

    /// Quit and Force Quit: not for macOS's own processes (the helper is read-only).
    public var canQuit: Bool {
        appID != AppIdentity.system.id
    }

    /// Get Info: any process; an app's first process, except macOS's.
    public var canGetInfo: Bool {
        switch self {
        case .app: canQuit
        case .process: true
        }
    }

    /// Show in Finder: app rows. Whether there's a bundle to show is checked when it runs.
    public var canShowInFinder: Bool {
        switch self {
        case .app: canQuit
        case .process: false
        }
    }

    /// The process Get Info opens: the selected one, or the app's oldest (lowest PID), which is
    /// the one the app started as. Nil when the app is gone from the list.
    func infoPID(in processesByApp: [AppIdentity.ID: [ProcessSample]]) -> Int32? {
        switch self {
        case let .process(pid, _): pid
        case let .app(id): processesByApp[id]?.map(\.pid).min()
        }
    }
}

/// The Process menu and the metric tabs' toolbar act on the selected row. Every quit still goes
/// through `requestQuit` and so through `ConfirmedAction` (CLAUDE.md rule 4).
@MainActor
extension AppServices {
    /// The selection, while a metric tab (the only place with an app list) is showing.
    public var actionableSelection: AppListSelection? {
        navigation.selection.metricTab == nil ? nil : navigation.appListSelection
    }

    public func quitSelection(mode: TerminationMode) {
        guard let selection = actionableSelection, selection.canQuit, let data = metrics.appList else {
            return
        }
        switch selection {
        case let .app(id):
            if let app = data.apps.first(where: { $0.id == id }) {
                requestQuit(app, pids: (data.processesByApp[id] ?? []).map(\.pid), mode: mode)
            }
        case let .process(pid, app):
            if let process = data.processesByApp[app]?.first(where: { $0.pid == pid }) {
                requestQuit(process, mode: mode)
            }
        }
    }

    public func getInfoOnSelection() {
        guard let selection = actionableSelection, selection.canGetInfo else {
            return
        }
        navigation.inspectedPID = selection.infoPID(in: metrics.appList?.processesByApp ?? [:])
    }

    public func showSelectionInFinder() {
        guard let selection = actionableSelection, selection.canShowInFinder,
              let app = metrics.appList?.apps.first(where: { $0.id == selection.appID })
        else {
            return
        }
        showInFinder(app.app)
    }
}
