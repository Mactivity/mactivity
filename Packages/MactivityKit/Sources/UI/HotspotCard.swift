import Core
import Foundation
import Observation
import SwiftUI

/// Data used on an iPhone's hotspot (D-136): a session starts each time the connection turns
/// expensive, and every snapshot adds its per-app data while it stays so. The Network tab and the
/// menu bar window show it; the 10-minute check alerts on an app using a lot.
@MainActor
@Observable
public final class HotspotModel {
    public private(set) var isExpensive = false
    public private(set) var isConstrained = false
    /// The current session, or the last one until the next begins.
    public private(set) var session: HotspotSession?

    public init() {}

    /// A session already going: render tests and screenshots.
    init(session: HotspotSession) {
        isExpensive = true
        self.session = session
    }

    /// When the connection last stopped being expensive.
    @ObservationIgnored private var leftAt: Date?
    /// A drop shorter than this (a sleep, the iPhone's hotspot reconnecting) continues the same
    /// session rather than starting from zero.
    static let reconnectGrace: TimeInterval = 15 * 60

    public func update(isExpensive: Bool, isConstrained: Bool, now: Date = Date()) {
        if isExpensive, !self.isExpensive {
            let reconnected = leftAt.map { now.timeIntervalSince($0) < Self.reconnectGrace } ?? false
            if session == nil || !reconnected {
                session = HotspotSession(start: now)
            }
        } else if !isExpensive, self.isExpensive {
            leftAt = now
        }
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Each snapshot, from the pipeline: nothing to do off a hotspot.
    public func record(_ snapshot: Snapshot) {
        guard isExpensive else {
            return
        }
        session?.add(snapshot)
    }

    /// Per app since the last call, for the 10-minute alert check; empty off a hotspot.
    public func takeRecent() -> [HotspotSession.Usage] {
        guard isExpensive else {
            return []
        }
        return session?.takeRecent() ?? []
    }
}

/// The Network tab's card while on a hotspot.
struct HotspotCard: View {
    let model: HotspotModel
    /// An app's history page (D-196).
    var openApp: (AppIdentity) -> Void = { _ in }

    var body: some View {
        if model.isExpensive, let session = model.session {
            GroupBox {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack {
                        Label {
                            Text("On a metered connection, like your iPhone's hotspot", bundle: .strings)
                                .font(Tokens.Typography.cardTitle)
                        } icon: {
                            Image(systemName: "personalhotspot")
                        }
                        Spacer()
                        Text(Formatters.bytes(session.totalBytes))
                            .font(Tokens.Typography.cardTitle)
                            .monospacedDigit()
                    }
                    Text(summary(session))
                        .foregroundStyle(.secondary)
                    ForEach(session.top.prefix(4)) { usage in
                        HStack {
                            AppIconView(usage.app)
                            Text(usage.app.name)
                            Spacer()
                            Text(Formatters.bytes(usage.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                        .onTapGesture { openApp(usage.app) }
                        .accessibilityAddTraits(.isButton)
                        .help(Text(
                            "Show \(usage.app.name)’s history",
                            bundle: .strings,
                            comment: "Tooltip on a top app: opens its history page"
                        ))
                    }
                }
            }
        }
    }

    private func summary(_ session: HotspotSession) -> String {
        let since = session.start.formatted(date: .omitted, time: .shortened)
        return model.isConstrained
            ? String(localized: "Used since \(since). Low Data Mode is on, so macOS holds back background downloads.", bundle: .strings)
            : String(
                localized: """
                Used since \(since). Mactivity alerts you when an app uses a lot; Low Data Mode, in Wi-Fi settings, \
                holds back background downloads.
                """,
                bundle: .strings
            )
    }
}
