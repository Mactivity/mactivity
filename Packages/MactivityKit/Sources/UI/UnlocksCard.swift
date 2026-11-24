import Core
import Observation
import SwiftUI

/// Unlocks' state (D-288). A read of macOS's log takes several seconds, so it runs when the card
/// shows, off the main thread, and the answer is kept for five minutes.
@MainActor
@Observable
public final class UnlocksModel {
    public private(set) var reading: UnlockReading?
    @ObservationIgnored private var source: any UnlockHistorySource
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var inProgress = false

    static let keepFor: TimeInterval = 300

    public init(source: any UnlockHistorySource) {
        self.source = source
    }

    public func replaceSource(_ source: any UnlockHistorySource) {
        self.source = source
        reading = nil
        readAt = nil
    }

    func load(now: Date = Date()) async {
        if let readAt, now.timeIntervalSince(readAt) < Self.keepFor, now >= readAt {
            return
        }
        guard !inProgress else {
            return
        }
        inProgress = true
        defer { inProgress = false }
        let source = source
        let found = await source.read(now: now)
        // A card gone before this finished still leaves a good answer for its return.
        reading = found
        readAt = now
    }
}

/// On the Security page (D-288): when this Mac was unlocked and how, and any failed attempts macOS
/// logged. Never says none failed: it can't know.
struct UnlocksCard: View {
    let model: UnlocksModel

    @State private var showsAll = false

    static let recentShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Unlocks", bundle: .strings, comment: "Security page: when this Mac was unlocked and how")
                    .font(Tokens.Typography.cardTitle)
                Spacer()
                if case let .read(found)? = model.reading, let from = found.coveredFrom {
                    Text(UnlockText.span(from))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            switch model.reading {
            case nil:
                HStack(spacing: Tokens.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    secondary(String(localized: "Reading macOS's log, which takes a few seconds.", bundle: .strings))
                }
            case .unreadable?:
                secondary(String(
                    localized: "Mactivity can't read this from macOS's log on this Mac, so it can't say when it was unlocked.",
                    bundle: .strings
                ))
            case let .read(found)?:
                results(found)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task { await model.load() }
    }

    @ViewBuilder private func results(_ found: UnlockLogReading) -> some View {
        if found.unlocks.isEmpty {
            secondary(String(
                localized: "No unlocks found in macOS's log. If this Mac has been unlocked lately, macOS may have changed what it writes.",
                bundle: .strings
            ))
        } else {
            Text(UnlockText.summary(found))
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
            failures(found.failures)
            let shown = showsAll ? found.unlocks : Array(found.unlocks.prefix(Self.recentShown))
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.xxs) {
                ForEach(shown) { unlock in
                    GridRow {
                        Text(unlock.at.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(UnlockText.method(unlock.method))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(Tokens.Typography.secondary)
            if found.unlocks.count > Self.recentShown {
                Button(showsAll ? String(localized: "Show Fewer", bundle: .strings) : String(localized: "Show All", bundle: .strings)) {
                    showsAll.toggle()
                }
                .buttonStyle(.link)
            }
        }
        secondary(String(
            localized: """
            From macOS's log, which keeps these for about a week. Logging in after a restart isn't counted, nor is waking a \
            Mac that didn't ask for a password.
            """,
            bundle: .strings
        ))
    }

    @ViewBuilder private func failures(_ failures: [FailedUnlock]) -> some View {
        if failures.isEmpty {
            secondary(String(
                localized: """
                Failed attempts: none found, which isn't proof there were none. macOS doesn't document these lines, so one \
                might not show up here.
                """,
                bundle: .strings
            ))
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(UnlockText.failedCount(failures.count))
                    .foregroundStyle(Tokens.Colors.strainLabel)
                ForEach(failures.prefix(Self.recentShown)) { failure in
                    Text(verbatim: "\(failure.at.formatted(date: .abbreviated, time: .shortened)) · \(UnlockText.failure(failure.kind))")
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Unlocks' words (D-288). Pure.
enum UnlockText {
    static func method(_ method: UnlockMethod) -> String {
        switch method {
        case .touchID: "Touch ID"
        case .password: String(localized: "Password", bundle: .strings, comment: "Unlocks: how the Mac was unlocked")
        case .appleWatch: "Apple Watch"
        case .unknown:
            String(localized: "macOS's log didn't say how", bundle: .strings, comment: "Unlocks: how the Mac was unlocked isn't known")
        }
    }

    static func failure(_ kind: FailedUnlock.Kind) -> String {
        switch kind {
        case .password: String(localized: "A wrong password", bundle: .strings, comment: "Unlocks: a failed attempt")
        case .touchID: String(localized: "A finger Touch ID didn't recognize", bundle: .strings, comment: "Unlocks: a failed attempt")
        case .other:
            String(localized: "A failed attempt, macOS's log didn't say how", bundle: .strings, comment: "Unlocks: a failed attempt")
        }
    }

    static func failedCount(_ count: Int) -> String {
        String(localized: "\(count) failed attempts found in macOS's log", bundle: .strings, comment: "Unlocks: count of failed attempts")
    }

    /// "41 unlocks: Touch ID 40, Password 1."
    static func summary(_ found: UnlockLogReading) -> String {
        let parts = found.byMethod.map { "\(method($0.method)) \($0.count)" }.joined(separator: ", ")
        return String(
            localized: "\(found.unlocks.count) unlocks: \(parts)", bundle: .strings,
            comment: "Unlocks: the total, then how many each way"
        )
    }

    static func span(_ from: Date) -> String {
        String(
            localized: "Since \(from.formatted(date: .abbreviated, time: .omitted))", bundle: .strings,
            comment: "Unlocks: how far back macOS's log reaches"
        )
    }
}
