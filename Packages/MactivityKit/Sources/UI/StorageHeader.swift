import Core
import Storage
import SwiftUI

/// The volume card: name, capacity bar split into used, purgeable, and free, and the Scan
/// control with progress while a scan runs.
struct StorageVolumeCard: View {
    let model: StorageModel
    let cleanups: StorageCleanups

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                Image(systemName: "internaldrive.fill")
                    .font(Tokens.Typography.cardSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.IconSize.card, height: Tokens.IconSize.card)
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(model.volume?.name ?? String(localized: "Startup Disk", bundle: .strings))
                        .font(Tokens.Typography.cardTitle)
                    Text(subtitle)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                StorageCleanUpMenu(cleanups: cleanups)
                scanControl
            }
            if let volume = model.volume {
                CapacityBar(volume: volume)
                CapacityLegend(volume: volume) { cleanups.purgeable.open() }
            }
            if case let .scanning(progress) = model.phase {
                ScanProgressRow(progress: progress, home: model.home)
            }
        }
        .cardStyle()
    }

    private var subtitle: String {
        guard let volume = model.volume else {
            return String(localized: "Reading volume…", bundle: .strings, comment: "A disk volume's size is being read (not audio volume)")
        }
        let available = String(
            localized: "\(Formatters.bytes(volume.free + volume.purgeable)) available",
            bundle: .strings,
            comment: "Volume card: free plus purgeable space"
        )
        // When Time Machine last backed up, if it's set up (D-216).
        let backup = model.timeMachine?.lastBackup.map {
            String(
                localized: "Backed up \($0.formatted(.relative(presentation: .named)))",
                bundle: .strings,
                comment: "Storage: when Time Machine last backed up, e.g. Backed up 2 hours ago"
            )
        }
        return ((volume.format.isEmpty ? [] : [volume.format]) + [Formatters.bytes(volume.capacity), available] + [backup]
            .compactMap { $0 })
            .joined(separator: " · ")
    }

    @ViewBuilder private var scanControl: some View {
        if model.isScanning {
            Button(String(localized: "Stop", bundle: .strings, comment: "Button: stops a scan, a dev server, or a container")) {
                model.stop()
            }
        } else {
            Menu {
                Button(String(localized: "Home Folder", bundle: .strings)) { model.start(.home) }
                Button(model.volume?.name ?? String(localized: "Startup Disk", bundle: .strings)) { model.start(.startupDisk) }
                Divider()
                Button(String(localized: "Choose Folder…", bundle: .strings)) { model.chooseFolder() }
            } label: {
                Label(
                    model.scan == nil
                        ? String(localized: "Scan", bundle: .strings, comment: "Button: starts a storage scan")
                        : String(localized: "Rescan", bundle: .strings),
                    systemImage: "arrow.clockwise"
                )
            } primaryAction: {
                model.start()
            }
            .menuStyle(.button)
            .fixedSize()
            .help(rescanHelp)
        }
    }

    private var rescanHelp: String {
        switch model.target {
        case .home:
            String(localized: "Scan your home folder again. Use the menu to pick another place.", bundle: .strings)
        case .startupDisk:
            String(localized: "Scan the startup disk again. Use the menu to pick another place.", bundle: .strings)
        case let .folder(url):
            String(
                localized: "Scan \(url.lastPathComponent) again. Use the menu to pick another place.",
                bundle: .strings,
                comment: "Help tag: the folder's name"
            )
        }
    }
}

/// Used, purgeable, and free as one bar, the way Finder and System Settings draw it.
struct CapacityBar: View {
    let volume: VolumeSummary

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let total = Double(max(volume.capacity, 1))
        SegmentedBar(
            segments: [
                .init(id: "used", fraction: Double(volume.used) / total, color: StorageTokens.usedColor),
                .init(id: "purgeable", fraction: Double(volume.purgeable) / total, color: StorageTokens.purgeableColor(contrast)),
                .init(id: "free", fraction: Double(volume.free) / total, color: StorageTokens.freeColor(contrast)),
            ],
            lastFillsRemainder: true
        )
        .frame(height: StorageTokens.capacityBarHeight)
        .accessibilityElement()
        .accessibilityLabel(Text(
            "\(Formatters.bytes(volume.used)) used, \(Formatters.bytes(volume.purgeable)) purgeable, \(Formatters.bytes(volume.free)) free",
            bundle: .strings,
            comment: "VoiceOver for the capacity bar"
        ))
    }
}

/// Segments side by side in one rounded bar, each as wide as its share: the capacity bar and the
/// category bar.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        /// Share of the bar's width, 0...1.
        let fraction: Double
        let color: Color
        var help: Text?
    }

    let segments: [Segment]
    /// The last segment takes whatever width is left (the capacity bar's free space) and absorbs
    /// the gaps. Otherwise each segment gives up one gap's width so the bar keeps its length.
    var lastFillsRemainder = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: StorageTokens.capacitySegmentGap) {
                ForEach(segments) { segment in
                    let fills = lastFillsRemainder && segment.id == segments.last?.id
                    let width = proxy.size.width * segment.fraction - (lastFillsRemainder ? 0 : StorageTokens.capacitySegmentGap)
                    let bar = Rectangle()
                        .fill(segment.color)
                        .frame(width: fills ? nil : max(0, width))
                        .frame(maxWidth: fills ? .infinity : nil)
                    if let help = segment.help {
                        bar.help(help)
                    } else {
                        bar
                    }
                }
            }
            .clipShape(Tokens.Shapes.tag)
        }
    }
}

struct CapacityLegend: View {
    let volume: VolumeSummary
    /// Opens Purgeable Space (D-125); the legend entry is its button.
    var openPurgeable: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Tokens.Spacing.l) {
            item(String(localized: "Used", bundle: .strings, comment: "Disk space legend"), volume.used, StorageTokens.usedColor)
                .help(VolumeSummary.snapshotNote)
            Button {
                openPurgeable?()
            } label: {
                item(
                    String(localized: "Purgeable", bundle: .strings, comment: "Disk space legend"),
                    volume.purgeable,
                    StorageTokens.purgeableColor(contrast)
                )
            }
            .buttonStyle(.plain)
            .disabled(openPurgeable == nil)
            .help(Text("Caches and iCloud copies macOS removes on its own when it needs the space. Click for details.", bundle: .strings))
            item(
                String(localized: "Free", bundle: .strings, comment: "Disk: free space (a figure label and a legend entry)"),
                volume.free,
                StorageTokens.freeColor(contrast)
            )
            Spacer()
            Label(String(localized: "Snapshots are counted in Used", bundle: .strings), systemImage: "info.circle")
                .labelStyle(.titleAndIcon)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
                .help(VolumeSummary.snapshotNote)
        }
        .font(Tokens.Typography.secondary)
    }

    private func item(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: StorageTokens.legendDot, height: StorageTokens.legendDot)
            Text(title)
                .foregroundStyle(.secondary)
            Text(Formatters.bytes(bytes))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScanProgressRow: View {
    let progress: StorageScanProgress?
    let home: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ProgressView()
                .controlSize(.small)
            if let progress {
                Text(verbatim: "\(StorageText.files(progress.filesScanned)) · \(Formatters.bytes(progress.bytesScanned))")
                    .monospacedDigit()
                Text(Formatters.displayPath(progress.currentPath, home: home))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Starting…", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
        }
        .font(Tokens.Typography.secondary)
    }
}

/// One-time explainer when Full Disk Access is off (spec E10): what's missing and how to fix it.
struct FullDiskAccessExplainer: View {
    let model: StorageModel
    @AppStorage(PreferenceKey.fullDiskAccessExplainerDismissed) private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "lock.shield")
                    .font(Tokens.Typography.cardSymbol)
                    .foregroundStyle(Tokens.Colors.accent)
                    .frame(width: StorageTokens.Layout.explainerSymbol)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Full Disk Access gives a complete map", bundle: .strings)
                        .font(Tokens.Typography.cardTitle)
                    // No `fixedSize(vertical:)` here: SwiftUI sizes the window's minimum by
                    // measuring at zero width, where fixed-height wrapped text is thousands of
                    // points tall. That pushed the Storage page (and the sidebar) off screen.
                    Text(StorageText.fullDiskAccessExplainer)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.xs) {
                        Button(String(localized: "Open Privacy & Security…", bundle: .strings)) { model.openFullDiskAccessSettings() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Not Now", bundle: .strings)) { dismissed = true }
                    }
                    .controlSize(.small)
                    .padding(.top, Tokens.Spacing.xxs)
                }
                Spacer(minLength: 0)
            }
            .cardStyle()
        }
    }
}
