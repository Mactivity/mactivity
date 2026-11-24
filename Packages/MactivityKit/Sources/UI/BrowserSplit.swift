import Core
import SwiftUI

/// Renderer arguments, read once per process (D-154): they never change, and only renderers of
/// an expanded row are read, so a sysctl or two per new tab.
@MainActor
final class ProcessArgumentsCache {
    private var cache: [Int32: [String]] = [:]

    func arguments(for processes: [ProcessSample], source: any ProcessArgumentReading) -> [Int32: [String]] {
        var found: [Int32: [String]] = [:]
        for process in processes where BrowserProcessKind.needsArguments(process.name) {
            if let known = cache[process.pid] {
                found[process.pid] = known
            } else {
                let arguments = source.arguments(process.pid)
                cache[process.pid] = arguments
                found[process.pid] = arguments
            }
        }
        if cache.count > 2000 {
            cache = found
        }
        return found
    }
}

extension BrowserProcessKind {
    func title(isBrowser: Bool) -> String {
        switch self {
        case .main:
            if isBrowser {
                String(localized: "Browser", bundle: .strings, comment: "Browser split: the main browser process")
            } else {
                String(localized: "App", bundle: .strings, comment: "Browser split: the app's main process")
            }
        case .pages:
            if isBrowser {
                String(localized: "Tabs", bundle: .strings, comment: "Browser split: tab processes")
            } else {
                String(localized: "Windows", bundle: .strings, comment: "Browser split: an Electron app's window processes")
            }
        case .extensions: String(localized: "Extensions", bundle: .strings, comment: "Browser split")
        case .gpu: String(localized: "GPU", bundle: .strings, comment: "Browser split: the GPU process")
        case .network: String(localized: "Network", bundle: .strings, comment: "Browser split: the network process")
        case .plugins: String(localized: "Plug-ins", bundle: .strings, comment: "Browser split")
        case .utility: String(localized: "Other", bundle: .strings, comment: "Browser split: helper processes")
        }
    }
}

extension BrowserProcessKind {
    /// One process's role, beside its name; nil where the name already says it all.
    func rowTitle(isBrowser: Bool) -> String? {
        switch self {
        case .main, .utility: nil
        case .pages:
            if isBrowser {
                String(localized: "Tab", bundle: .strings, comment: "Browser split: one process that holds tabs")
            } else {
                String(localized: "Window", bundle: .strings, comment: "Browser split: one Electron window process")
            }
        case .extensions: String(localized: "Extension", bundle: .strings, comment: "Browser split: one extension's process")
        case .gpu: String(localized: "GPU", bundle: .strings, comment: "Browser split: the GPU process")
        case .network: String(localized: "Network", bundle: .strings, comment: "Browser split: the network process")
        case .plugins: String(localized: "Plug-in", bundle: .strings, comment: "Browser split")
        }
    }
}

/// "Tabs 14 · 2.1 GB   Extensions 4 · 380 MB   GPU · 410 MB…", over an expanded browser's processes.
struct BrowserSplitRow: View {
    let groups: [BrowserProcessKind.Group]
    let metric: Metric
    let total: Double?
    let isBrowser: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(groups)
            line(Array(groups.prefix(3)))
        }
        .font(Tokens.Typography.secondary)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func line(_ shown: [BrowserProcessKind.Group]) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            ForEach(shown) { group in
                HStack(spacing: Tokens.Spacing.xxs) {
                    Text(group.kind.title(isBrowser: isBrowser)).foregroundStyle(.primary)
                    if group.count > 1 {
                        Text(group.count.formatted())
                    }
                    Text(verbatim: "·")
                    Text(AppListView.valueText(group.value, metric: metric, total: total)).monospacedDigit()
                }
                .fixedSize()
            }
        }
    }
}
