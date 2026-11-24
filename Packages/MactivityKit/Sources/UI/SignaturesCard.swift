import Core
import Observation
import Projects
import SwiftUI

/// Who made what's running's state (D-232): each running app's signer, read when the CPU tab
/// shows and every minute while it does. Each program is read once per version.
@MainActor
@Observable
final class SignaturesModel {
    private let source: any CodeSignatureSource
    /// App ID → its signer.
    private(set) var signers: [AppIdentity.ID: Signer] = [:]
    private(set) var loaded = false

    init(source: any CodeSignatureSource) {
        self.source = source
    }

    func load(_ snapshot: Snapshot?) async {
        guard let snapshot else {
            return
        }
        let apps = snapshot.apps.filter { $0.app.kind != .system }
        // An app's bundle; otherwise the program its first process runs.
        let firstPID = Dictionary(snapshot.processes.map { ($0.app, $0.pid) }, uniquingKeysWith: { first, _ in first })
        let needExecutables = apps.filter { !$0.app.iconKey.hasSuffix(".app") }.compactMap { firstPID[$0.id] }
        let executables = await source.executables(needExecutables)
        var pathOf: [AppIdentity.ID: String] = [:]
        for app in apps {
            if app.app.iconKey.hasSuffix(".app") {
                pathOf[app.id] = app.app.iconKey
            } else if let pid = firstPID[app.id], let path = executables[pid] {
                pathOf[app.id] = path
            }
        }
        let byPath = await source.signers(of: Array(pathOf.values))
        signers = pathOf.compactMapValues { byPath[$0] }
        loaded = true
    }
}

/// On the CPU tab: who made each running app, with the ones nobody's name is on set apart.
struct SignaturesCard: View {
    let model: SignaturesModel
    let metrics: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text("Who made what's running", bundle: .strings, comment: "CPU tab card: the signer of each running app")
                    .font(Tokens.Typography.cardTitle)
                if model.loaded {
                    Text(summary)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.loaded {
                let groups = groups
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Text(group.title)
                            .foregroundStyle(group.flagged ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.primary))
                            .frame(minWidth: 180, alignment: .leading)
                        Text(group.apps.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                            .formatted(.list(type: .and)))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(Tokens.Typography.secondary)
                    .accessibilityElement(children: .combine)
                }
                if groups.contains(where: \.flagged) {
                    Text(
                        """
                        Nobody's name is on these: built on this Mac, installed by a package manager like Homebrew, or unsigned. \
                        That's normal for your own builds and tools; be wary of one you don't recognize.
                        """,
                        bundle: .strings
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task {
            while !Task.isCancelled {
                await model.load(metrics.snapshot)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private struct Group {
        let title: String
        let apps: [AppIdentity]
        let flagged: Bool
    }

    /// Unsigned, then signed on this Mac, then each developer by how many of their apps run,
    /// then the App Store and Apple.
    private var groups: [Group] {
        let apps = (metrics.snapshot?.apps ?? []).map(\.app).filter { model.signers[$0.id] != nil }
        var bySigner: [Signer: [AppIdentity]] = [:]
        for app in apps {
            if let signer = model.signers[app.id], signer != .unknown {
                bySigner[signer, default: []].append(app)
            }
        }
        var groups: [Group] = []
        if let unsigned = bySigner[.unsigned] {
            groups.append(Group(
                title: String(localized: "Unsigned", bundle: .strings, comment: "Code signature group"),
                apps: unsigned,
                flagged: true
            ))
        }
        if let local = bySigner[.adHoc] {
            groups.append(Group(
                title: String(localized: "Signed on this Mac", bundle: .strings, comment: "Code signature group: ad hoc"), apps: local,
                flagged: true
            ))
        }
        let developers = bySigner.compactMap { signer, apps -> (String, [AppIdentity])? in
            switch signer {
            case let .developer(name, _): (name, apps)
            case let .development(name): (
                    String(localized: "\(name), development build", bundle: .strings, comment: "Code signature group"),
                    apps
                )
            default: nil
            }
        }
        .sorted { ($1.1.count, $0.0) < ($0.1.count, $1.0) }
        groups += developers.map { Group(title: $0.0, apps: $0.1, flagged: false) }
        if let store = bySigner[.appStore] {
            groups.append(Group(
                title: String(localized: "Mac App Store", bundle: .strings, comment: "Code signature group"),
                apps: store,
                flagged: false
            ))
        }
        if let apple = bySigner[.apple] {
            groups.append(Group(
                title: String(localized: "Apple", bundle: .strings, comment: "Code signature group"),
                apps: apple,
                flagged: false
            ))
        }
        return groups
    }

    /// "24 apps from 11 developers; 2 with nobody's name on them".
    private var summary: String {
        let signers = model.signers.values.filter { $0 != .unknown }
        // Apps by identified developers only: Apple's and the App Store's aren't "from" them (D-236).
        let identified = signers.compactMap { signer -> String? in
            if case let .developer(name, _) = signer {
                return name
            }
            return nil
        }
        let names = Set(identified)
        let anonymous = signers.filter(\.isAnonymous).count
        let base = String(
            localized: "\(identified.count) apps from \(names.count) identified developers",
            bundle: .strings,
            comment: "Code signatures summary: running apps, how many identified developers made them"
        )
        guard anonymous > 0 else {
            return base
        }
        return base + String(
            localized: "; \(anonymous) with nobody's name on them",
            bundle: .strings,
            comment: "Code signatures summary, after the apps: how many are unsigned or signed on this Mac"
        )
    }
}
