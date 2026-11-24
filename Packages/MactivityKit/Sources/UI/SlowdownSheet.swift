import Core
import Foundation
import Observation
import SwiftUI

/// "Why is my Mac slow?" (D-134): a few seconds of snapshots with macOS's own processes read,
/// then `Slowdown.diagnose`. Opened from the toolbar, the menu bar window, and Quick Search.
@MainActor
@Observable
public final class SlowdownModel {
    public enum State: Equatable {
        case idle, looking
        case done([SlowdownCause])
        /// Nothing sampled yet (just launched): no evidence either way (D-142).
        case noData
    }

    public var isPresented = false
    public private(set) var state = State.idle
    /// Slowdowns History saw in the last week (D-169), loaded alongside the live look.
    private(set) var earlier: [EarlierSlowdown] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Snapshots averaged; a few seconds evens out a passing spike.
    static let wanted = 3
    static let timeout: Duration = .seconds(8)

    public init() {}

    /// Already diagnosed: render tests and screenshots.
    init(causes: [SlowdownCause], earlier: [EarlierSlowdown] = []) {
        state = .done(causes)
        self.earlier = earlier
        isPresented = true
    }

    public func open(_ services: AppServices) {
        isPresented = true
        look(services)
    }

    public func look(_ services: AppServices) {
        task?.cancel()
        state = .looking
        let history = services.history
        task = Task { [weak self] in
            async let past = EarlierSlowdown.load(history, now: Date())
            var snapshots = await Self.collect(services.metrics)
            // The demo video's simulated copy shows a busy moment (DemoTour.busyMoment).
            if LaunchOverrides.isDemoTour, services.metrics.isSimulated, let last = snapshots.last {
                snapshots = DemoTour.busyMoment(last)
            }
            let unused = await UnusedAppsModel.find(services)
            let earlier = await past
            guard let self, !Task.isCancelled else {
                return
            }
            self.earlier = earlier
            guard !snapshots.isEmpty else {
                state = .noData
                return
            }
            state = .done(Slowdown.diagnose(snapshots, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, unused: unused))
        }
    }

    public func close() {
        task?.cancel()
        isPresented = false
    }

    /// Turns on macOS's process detail, skips the first detailed snapshot (its processes have no
    /// CPU figure yet: that needs two readings), and keeps the next few.
    static func collect(_ metrics: LiveMetrics) async -> [Snapshot] {
        metrics.setSystemDetail(true, for: .diagnosis)
        defer { metrics.setSystemDetail(false, for: .diagnosis) }
        var collected: [Snapshot] = []
        var last = metrics.snapshot?.at
        var skipped = false
        let deadline = ContinuousClock.now + timeout
        while collected.count < wanted, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard let snapshot = metrics.snapshot, snapshot.at != last else {
                continue
            }
            last = snapshot.at
            if skipped {
                collected.append(snapshot)
            } else {
                skipped = true
            }
        }
        // Too slow a cadence to get more: whatever arrived, or at least the latest.
        if collected.isEmpty, let latest = metrics.snapshot {
            collected = [latest]
        }
        return collected
    }
}

struct SlowdownSheet: View {
    let services: AppServices
    @Bindable var model: SlowdownModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "gauge.with.needle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Why is my Mac slow?", bundle: .strings)
                        .font(Tokens.Typography.headline)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // Now and the last 7 days in one scrolling list, so the sheet never gets taller than
            // a small screen (two lists stacked, each with its own cap, could reach ~870 pt; D-175).
            if case .done = model.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                        content
                        if !model.earlier.isEmpty {
                            EarlierSlowdownsSection(slowdowns: model.earlier) { app in
                                model.close()
                                // One sheet at a time: the history page opens once this one has gone.
                                Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    services.appHistory.open(app)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: Tokens.Layout.diagnosisListMaxHeight)
            } else {
                content
            }
            HStack {
                Button(String(localized: "Check Again", bundle: .strings)) { model.look(services) }
                    .disabled(model.state == .looking)
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.close() }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too, as Return does: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.close() }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 560)
        .confirmedActionDialog(services.confirmedAction, presenter: .sheet)
    }

    private var subtitle: String {
        switch model.state {
        case .idle, .looking:
            String(localized: "Watching your Mac for a few seconds…", bundle: .strings)
        case .noData:
            String(localized: "Mactivity has nothing to go on yet. Try again in a few seconds.", bundle: .strings)
        case let .done(causes) where causes.isEmpty:
            String(localized: "Nothing is slowing your Mac right now.", bundle: .strings)
        case .done:
            String(localized: "What's slowing it now, most important first.", bundle: .strings)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .looking:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .noData:
            Color.clear.frame(height: 40)
        case let .done(causes) where causes.isEmpty && !model.earlier.isEmpty:
            // The subtitle says it's clear; the slowdowns below are the rest of the answer.
            EmptyView()
        case let .done(causes) where causes.isEmpty:
            ContentUnavailableView {
                Label(String(localized: "All clear", bundle: .strings), systemImage: "checkmark.seal")
            } description: {
                Text("If it felt slow a moment ago, the CPU and Memory tabs show the last hour.", bundle: .strings)
            }
            // The full width, as the spinner before it: in a leading stack it sat left of center.
            .frame(maxWidth: .infinity, minHeight: 160)
        case let .done(causes):
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                ForEach(causes) { cause in
                    row(cause)
                }
            }
        }
    }

    private func row(_ cause: SlowdownCause) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: Self.symbol(cause.kind))
                .foregroundStyle(cause.severity == .major ? Color.orange : Color.secondary)
                .frame(width: Tokens.IconSize.card)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(cause.title).font(Tokens.Typography.cardTitle)
                Text(cause.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Spacing.s)
            switch cause.action {
            case let .quit(app):
                Button(String(localized: "Quit…", bundle: .strings)) { services.requestQuit(appID: app.id, presenter: .sheet) }
                    .disabled(!services.canTerminate(app))
            case let .show(destination):
                Button(String(localized: "Show", bundle: .strings)) {
                    model.close()
                    services.navigation.show(Self.sidebarItem(destination))
                }
            case .showUnusedApps:
                Button(String(localized: "Show", bundle: .strings)) {
                    model.close()
                    // One sheet at a time: the list opens once this one has gone.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        services.unusedApps.open(services)
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .padding(Tokens.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
    }

    static func sidebarItem(_ destination: SlowdownCause.Destination) -> SidebarItem {
        switch destination {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .storage: .storage
        case .gpu: .gpu
        case .battery: .battery
        }
    }

    static func symbol(_ kind: SlowdownCause.Kind) -> String {
        switch kind {
        case .busyCPU, .busyApp: "cpu"
        case .memory, .swap: "memorychip"
        case .heat: "thermometer.high"
        case .diskFull: "internaldrive"
        case .diskBusy: "externaldrive.badge.timemachine"
        case .gpu: "rectangle.3.group"
        case .lowPower: "battery.25percent"
        case .spotlight: "magnifyingglass"
        case .timeMachine: "clock.arrow.circlepath"
        case .photos: "photo.on.rectangle"
        case .iCloud: "icloud"
        case .softwareUpdate: "arrow.down.app"
        case .malwareScan: "checkmark.shield"
        case .windowServer: "macwindow.on.rectangle"
        case .unusedApps: "moon.zzz"
        }
    }
}

@MainActor
extension AppServices {
    /// Quit for an app named by ID (the diagnosis, Quick Search): its latest figures and
    /// processes, then the usual confirmation.
    public func requestQuit(appID: AppIdentity.ID, presenter: ConfirmedAction.Presenter) {
        guard let snapshot = metrics.snapshot, let app = snapshot.apps.first(where: { $0.id == appID }) else {
            return
        }
        let pids = snapshot.processes.filter { $0.app == appID }.map(\.pid)
        requestQuit(app, pids: pids, mode: .quit, presenter: presenter)
    }
}
