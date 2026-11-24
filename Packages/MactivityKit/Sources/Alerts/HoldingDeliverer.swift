import Core
import Foundation
import os

/// Quiet while you present (1.6): while the person presents, is on a call or records, alerts are
/// kept back, and when that's over one notification says what came in. They're recorded and
/// shown in Alerts as they fire; only the notifications wait.
///
/// Never for long, and never a new startup item (D-251): a microphone or camera some app keeps
/// running, or a display that's always mirrored, would otherwise silence every alert for good,
/// and a new startup item is how something unwanted stays on a Mac.
public actor HoldingDeliverer: AlertDeliverer {
    private static let logger = Logger(subsystem: "app.mactivity.alerts", category: "holding")

    private let inner: any AlertDeliverer
    private let presenting: any PresentingSource
    private let isEnabled: @Sendable () -> Bool
    private let summary: @Sendable (_ title: String, _ body: String) async throws -> Void
    private let checkEvery: Duration
    private let longest: Duration
    private let clock = ContinuousClock()
    /// When this stretch of presenting began; nil when not holding.
    private var since: ContinuousClock.Instant?
    /// Past `longest`, alerts go straight through until the presenting ends.
    private var gaveUp = false
    private(set) var held: [Alert] = []
    private var reason: PresentingReason?
    private var watch: Task<Void, Never>?

    public init(
        inner: any AlertDeliverer,
        presenting: any PresentingSource,
        isEnabled: @escaping @Sendable () -> Bool,
        checkEvery: Duration = .seconds(15),
        longest: Duration = .seconds(2 * 3600),
        summary: @escaping @Sendable (_ title: String, _ body: String) async throws -> Void
    ) {
        self.inner = inner
        self.presenting = presenting
        self.isEnabled = isEnabled
        self.checkEvery = checkEvery
        self.longest = longest
        self.summary = summary
    }

    public func deliver(_ alert: Alert) async throws {
        guard Self.mayHold(alert), isEnabled(), !gaveUp, let now = await presenting.current() else {
            try await inner.deliver(alert)
            return
        }
        held.append(alert)
        reason = reason ?? now
        since = since ?? clock.now
        startWatching()
    }

    /// Pure: a new startup item always comes through (D-251).
    static func mayHold(_ alert: Alert) -> Bool {
        alert.rule != .newStartupItem
    }

    /// Checks until the presenting is over, then says what came in.
    private func startWatching() {
        guard watch == nil else {
            return
        }
        watch = Task { [checkEvery] in
            while !Task.isCancelled {
                try? await Task.sleep(for: checkEvery)
                if await presenting.current() == nil {
                    await release()
                    endStretch()
                    return
                }
                if overdue() {
                    await release()
                }
            }
        }
    }

    /// Held for `longest`: what came in goes out now, and the rest of this stretch isn't held.
    private func overdue() -> Bool {
        guard !gaveUp, let since, clock.now - since >= longest else {
            return false
        }
        gaveUp = true
        return true
    }

    private func endStretch() {
        watch = nil
        since = nil
        gaveUp = false
    }

    /// Delivers what was held: one alert as itself, more as one summary.
    func release() async {
        let alerts = held
        let why = reason ?? .presenting
        held = []
        reason = nil
        guard !alerts.isEmpty else {
            return
        }
        do {
            if alerts.count == 1, let only = alerts.first {
                try await inner.deliver(only)
            } else {
                let text = Self.summaryText(alerts, reason: why)
                try await summary(text.title, text.body)
            }
        } catch {
            Self.logger.error("Couldn't deliver held alerts: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pure: "3 alerts while you were on a call", and their titles, newest first, up to four.
    public static func summaryText(_ alerts: [Alert], reason: PresentingReason) -> (title: String, body: String) {
        let count = alerts.count
        let title = switch reason {
        case .call: String(
                localized: "\(count) alerts while you were on a call",
                bundle: .strings,
                comment: "Held alerts' summary notification: how many, after a call or recording"
            )
        case .presenting, .mirroring: String(
                localized: "\(count) alerts while you were presenting",
                bundle: .strings,
                comment: "Held alerts' summary notification: how many, after presenting"
            )
        }
        let titles = alerts.sorted { $0.firedAt > $1.firedAt }.map(\.title)
        var lines = Array(titles.prefix(4))
        if titles.count > 4 {
            lines.append(String(
                localized: "And \(titles.count - 4) more in Alerts.",
                bundle: .strings,
                comment: "Held alerts' summary: the ones not listed"
            ))
        }
        return (title, lines.joined(separator: "\n"))
    }
}
