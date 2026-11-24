import AppKit
import Core
import Foundation
import Observation
import SwiftUI

/// Apps open but unused (D-135): Checkup's item opens this list, each app with Quit….
@MainActor
@Observable
public final class UnusedAppsModel {
    public var isPresented = false
    public private(set) var apps: [UnusedApp] = []
    public private(set) var isLoading = false
    /// The app whose Quit… was asked last: dropped from the list once the quit runs (D-142).
    var quitting: AppIdentity.ID?

    public init() {}

    /// Already found: render tests.
    init(apps: [UnusedApp]) {
        self.apps = apps
        isPresented = true
    }

    public func open(_ services: AppServices) {
        isPresented = true
        apps = []
        isLoading = true
        Task {
            apps = await Self.find(services)
            isLoading = false
        }
    }

    /// The confirmed quit ran: that app is no longer open.
    func quitFinished() {
        if let quitting {
            apps.removeAll { $0.id == quitting }
        }
        quitting = nil
    }

    /// From the latest snapshot, the regular apps running now, and time in front. Simulated
    /// data pairs with simulated time in front, so screenshots show the list too.
    static func find(_ services: AppServices, now: Date = Date()) async -> [UnusedApp] {
        // Without time in front being recorded, "unused" has no evidence (D-142).
        guard UserDefaults.standard.object(forKey: PreferenceKey.recordsTimeInFront) as? Bool ?? true,
              let snapshot = services.metrics.snapshot, let store = services.history as? any FocusStore
        else {
            return []
        }
        let running: [UnusedApps.Running] = services.metrics.isSimulated
            ? snapshot.apps.filter { $0.app.kind == .app }.map { UnusedApps.Running(
                id: $0.id,
                launchedAt: now.addingTimeInterval(-20 * 86400)
            ) }
            : NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { UnusedApps.Running(id: $0, launchedAt: app.launchDate) } }
        let lastFront = await (try? store.lastFocus()) ?? [:]
        // Only time Mactivity was running counts: quit for four days, it can't tell that Safari
        // was in use all along (D-142).
        let simulated = services.metrics.isSimulated
        let since = await (try? store.firstFocus()).flatMap(\.self).map { simulated ? $0 : max($0, services.launchedAt) }
        return UnusedApps.find(
            apps: snapshot.apps, running: running, lastFront: lastFront, recordingSince: since,
            own: Bundle.main.bundleIdentifier, now: now
        )
    }
}

struct UnusedAppsSheet: View {
    let services: AppServices
    @Bindable var model: UnusedAppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "moon.zzz")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Open but unused", bundle: .strings)
                        .font(Tokens.Typography.headline)
                    Text(
                        "Apps you haven't used for days, still holding memory. Quitting frees it; they open again when you need them.",
                        bundle: .strings
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 140)
            } else if model.apps.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing idle", bundle: .strings), systemImage: "checkmark.seal")
                } description: {
                    Text("Every app that's open has been used in the last 3 days.", bundle: .strings)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                List(model.apps) { item in
                    row(item)
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }
            HStack {
                if !model.apps.isEmpty {
                    let total = Formatters.memory(model.apps.reduce(0) { $0 + $1.memoryBytes })
                    Text("Together: \(total)", bundle: .strings)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too, as Return does: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 520)
        .confirmedActionDialog(services.confirmedAction, presenter: .sheet)
        .onChange(of: services.confirmedAction.isRunning) { was, running in
            if was, !running {
                model.quitFinished()
            }
        }
    }

    private func row(_ item: UnusedApp) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            AppIconView(item.app)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.app.name)
                Text(Self.lastUsed(item))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Formatters.memory(item.memoryBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(String(localized: "Quit…", bundle: .strings)) {
                model.quitting = item.id
                services.requestQuit(appID: item.id, presenter: .sheet)
            }
        }
    }

    static func lastUsed(_ item: UnusedApp) -> String {
        let days = Int(item.unusedFor / 86400)
        return item.lastUsed == nil
            ? String(localized: "Not used since it opened: \(days) days", bundle: .strings)
            : String(localized: "Last used \(days) days ago", bundle: .strings)
    }
}
