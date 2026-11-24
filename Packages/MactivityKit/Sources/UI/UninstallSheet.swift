import AppKit
import Core
import Observation
import Storage
import SwiftUI
import UniformTypeIdentifiers

/// App uninstaller (D-104): pick an app, see what it left in ~/Library, and move the ticked items
/// to the Trash after one confirmation. Nothing is deleted; everything can be put back.
@MainActor
@Observable
final class UninstallModel {
    private(set) var plan: UninstallPlan?
    /// Paths to move. Name-only matches start unticked.
    var selected: Set<String> = []
    private(set) var isPreparing = false
    private(set) var isRunning = false
    /// The confirmation dialog is up.
    var confirming = false
    /// Called after files were moved, so the Trash and Reclaimable refresh (D-119).
    var onMoved: () -> Void = {}
    private(set) var problem: String?

    init() {}

    /// Already planned: tests of what `perform` moves and refuses, without reading ~/Library.
    init(loaded plan: UninstallPlan) {
        show(plan)
    }

    /// Everything found by bundle ID starts ticked; a name-only match waits for the user.
    private func show(_ plan: UninstallPlan) {
        self.plan = plan
        selected = Set(plan.items.filter { !$0.matchedByName }.map(\.path))
    }

    /// Reads the app's bundle and sizes its leftovers off the main thread.
    func prepare(_ url: URL) async {
        isPreparing = true
        problem = nil
        defer { isPreparing = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<UninstallPlan, UninstallError> in
            do throws(UninstallError) {
                return try .success(AppLeftovers.plan(appURL: url))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(plan):
            show(plan)
        case .failure(.systemApp):
            problem = String(localized: "Apps that come with macOS can't be removed.", bundle: .strings)
        case .failure(.notAnApp):
            problem = String(localized: "That isn't an app.", bundle: .strings)
        }
    }

    func dismiss() {
        plan = nil
        selected = []
    }

    func clearProblem() {
        problem = nil
    }

    var isRunningApp: Bool {
        guard let plan else {
            return false
        }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: plan.bundleID).isEmpty
    }

    var selectedSize: UInt64 {
        plan?.items.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size } ?? 0
    }

    /// "Move Slack and 6 related items (1.4 GB) to the Trash?"
    var confirmationTitle: String {
        guard let plan else {
            return ""
        }
        let size = Formatters.bytes(selectedSize)
        let includesApp = selected.contains(plan.appPath)
        let others = selected.count - (includesApp ? 1 : 0)
        return includesApp
            ? String(
                localized: "Move \(plan.appName) and its files (\(size)) to the Trash?",
                bundle: .strings,
                comment: "Uninstall confirmation: the app, then the total size"
            )
            : String(
                localized: "Move \(plan.appName)'s leftover files (\(others), \(size)) to the Trash?",
                bundle: .strings,
                comment: "Uninstall confirmation: leftovers only, their count and size"
            )
    }

    /// The user confirmed: moves each ticked item. Creating the `TrashConfirmation`s here, right
    /// after the dialog's Move to Trash, is this flow's confirm step (the storage view's twin).
    func perform(using trasher: any StorageTrashing, toast: @escaping (String) -> Void) async {
        guard let plan, !isRunning else {
            return
        }
        isRunning = true
        defer { isRunning = false }
        var moved = 0
        var failed: [String] = []
        let leftovers = AppLeftovers.leftoverScope()
        for item in plan.items where selected.contains(item.path) {
            // Only the app picked, and leftovers at the top of the Library folders the plan
            // looks in, checked right before the Trash like every cleanup (D-123, D-140).
            guard item.kind == .app ? item.path == plan.appPath : leftovers.allows(item.path) else {
                failed.append((item.path as NSString).lastPathComponent)
                continue
            }
            do {
                _ = try await trasher.moveToTrash(TrashConfirmation(path: item.path, confirmedAt: Date()))
                moved += 1
            } catch {
                if item.kind == .app, await Self.recycleWithFinder(item.path) {
                    moved += 1
                } else {
                    failed.append((item.path as NSString).lastPathComponent)
                }
            }
        }
        dismiss()
        onMoved()
        if failed.isEmpty {
            toast(String(
                localized: "Moved \(plan.appName) and its files to the Trash. You can put them back from there.",
                bundle: .strings
            ))
        } else {
            let names = failed.formatted(.list(type: .and))
            toast(String(localized: "Moved to the Trash: \(moved). Couldn't move: \(names).", bundle: .strings))
        }
    }

    /// Apps installed by an administrator or from the App Store: Finder's way, which asks for a
    /// password when it has to. Still the Trash.
    static func recycleWithFinder(_ path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { moved, error in
                continuation.resume(returning: error == nil && !moved.isEmpty)
            }
        }
    }
}

struct UninstallSheet: View {
    @Bindable var model: UninstallModel
    let trasher: any StorageTrashing
    let toast: (String) -> Void

    var body: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                HStack(spacing: Tokens.Spacing.s) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: plan.appPath))
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                        Text("Uninstall \(plan.appName)", bundle: .strings)
                            .font(Tokens.Typography.headline)
                        Text("Everything ticked goes to the Trash, where you can put it back.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                }
                List {
                    ForEach(plan.items) { item in
                        Toggle(isOn: Binding(
                            get: { model.selected.contains(item.path) },
                            set: { on in
                                if on {
                                    model.selected.insert(item.path)
                                } else {
                                    model.selected.remove(item.path)
                                }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.title(item.kind))
                                    Text(Formatters.displayPath(item.path, home: NSHomeDirectory()))
                                        .font(Tokens.Typography.codeSecondary)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if item.matchedByName {
                                        Text("Found by name: check it's this app's.", bundle: .strings)
                                            .font(Tokens.Typography.secondary)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(Formatters.bytes(item.size))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 240)
                if model.isRunningApp, model.selected.contains(plan.appPath) {
                    Label(String(localized: "Quit \(plan.appName) first.", bundle: .strings), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tokens.Colors.strainLabel)
                }
                HStack {
                    Text("Selected: \(Formatters.bytes(model.selectedSize))", bundle: .strings)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(String(localized: "Cancel", bundle: .strings), role: .cancel) { model.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Move to Trash…", bundle: .strings), role: .destructive) { model.confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selected.isEmpty || model
                            .isRunning || (model.isRunningApp && model.selected.contains(plan.appPath)))
                }
            }
            .padding(Tokens.Spacing.l)
            .frame(width: 560)
            .confirmationDialog(model.confirmationTitle, isPresented: $model.confirming, titleVisibility: .visible) {
                Button(String(localized: "Move to Trash", bundle: .strings), role: .destructive) {
                    Task { await model.perform(using: trasher, toast: toast) }
                }
                Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {}
            } message: {
                Text("You can put everything back from the Trash.", bundle: .strings)
            }
        }
    }

    nonisolated static func title(_ kind: UninstallItem.Kind) -> String {
        switch kind {
        case .app: String(localized: "The app", bundle: .strings, comment: "Uninstall list: the app bundle itself")
        case .applicationSupport: String(localized: "App data", bundle: .strings)
        case .caches: String(localized: "Caches", bundle: .strings)
        case .preferences: String(localized: "Settings file", bundle: .strings, comment: "Uninstall list: a preferences plist")
        case .containers: String(localized: "App container", bundle: .strings)
        case .groupContainers: String(localized: "Shared container", bundle: .strings)
        case .savedState: String(localized: "Saved window state", bundle: .strings)
        case .webData: String(localized: "Web data and cookies", bundle: .strings)
        case .logs: String(localized: "Logs", bundle: .strings)
        case .launchAgents: String(localized: "Starts at login", bundle: .strings, comment: "Uninstall list: a launch agent")
        case .scripts: String(localized: "Scripts", bundle: .strings)
        }
    }
}
