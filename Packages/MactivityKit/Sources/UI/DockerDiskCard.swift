import Core
import Docker
import SwiftUI

/// Docker on Projects → Space (D-224): what images, volumes, build cache and stopped containers
/// take, what nothing uses, and the command that reclaims each, to copy and run yourself.
struct DockerDiskCard: View {
    let usage: DockerDiskUsage
    @State private var copied: DockerDiskUsage.Part?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Label {
                    Text(verbatim: "Docker").font(Tokens.Typography.cardTitle)
                } icon: {
                    Image(systemName: "cube.box")
                }
                Text(
                    "\(Formatters.bytes(usage.bytes)), \(Formatters.bytes(usage.reclaimable)) could be freed",
                    bundle: .strings,
                    comment: "Docker disk use: total, then what the prune commands would free"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
                ForEach(usage.totals.filter { $0.count >= 1 }, id: \.part) { total in
                    GridRow {
                        Text(Self.title(total.part, count: total.count))
                        Text(Formatters.bytes(total.bytes)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(Self.reclaimable(total))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        commandCell(total)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !usage.projects.isEmpty {
                let projects = usage.projects.prefix(4).map { "\($0.project) \(Formatters.bytes($0.bytes))" }.formatted(.list(type: .and))
                Text(
                    "By project: \(projects)",
                    bundle: .strings,
                    comment: "Docker disk use: compose projects and their sizes, e.g. By project: storefront 4.8 GB and analytics 2 GB"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            }
            Text(
                """
                Mactivity doesn't run these: pruning deletes for good, and a pruned volume's data is gone. \
                Images download or build again.
                """,
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder private func commandCell(_ total: DockerDiskUsage.Total) -> some View {
        if total.reclaimable > 0 {
            HStack(spacing: Tokens.Spacing.xs) {
                Text(verbatim: total.part.command)
                    .font(Tokens.Typography.codeSecondary)
                    .textSelection(.enabled)
                Button {
                    InspectorText.copy(total.part.command)
                    copied = total.part
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if copied == total.part {
                            copied = nil
                        }
                    }
                } label: {
                    Image(systemName: copied == total.part ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(Text("Copy the command", bundle: .strings))
                .accessibilityLabel(Text("Copy the command", bundle: .strings))
            }
        } else {
            Text(verbatim: "")
        }
    }

    /// What the part's prune frees, in its own words: an image no container uses, a stopped container.
    static func reclaimable(_ total: DockerDiskUsage.Total) -> String {
        let amount = Formatters.bytes(total.reclaimable)
        return switch total.part {
        case .images: String(localized: "\(amount) no container uses", bundle: .strings, comment: "Docker images: size of unused ones")
        case .volumes: String(localized: "\(amount) no container uses", bundle: .strings, comment: "Docker images: size of unused ones")
        case .buildCache: String(localized: "\(amount) not in use", bundle: .strings, comment: "Docker build cache: size no build uses now")
        case .containers: String(
                localized: "\(amount) in stopped ones",
                bundle: .strings,
                comment: "Docker containers: size of stopped ones"
            )
        }
    }

    static func title(_ part: DockerDiskUsage.Part, count: Int) -> String {
        switch part {
        case .images: String(localized: "Images (\(count))", bundle: .strings, comment: "Docker disk use row, with how many")
        case .volumes: String(localized: "Volumes (\(count))", bundle: .strings, comment: "Docker disk use row, with how many")
        case .buildCache: String(
                localized: "Build cache (\(count))",
                bundle: .strings,
                comment: "Docker disk use row, with how many records"
            )
        case .containers: String(localized: "Containers (\(count))", bundle: .strings, comment: "Docker disk use row, with how many")
        }
    }
}
