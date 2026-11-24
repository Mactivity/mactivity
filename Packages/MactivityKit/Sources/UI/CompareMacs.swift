import AppKit
import Core
import Export
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.mactivityreport` file (1.6), declared in the app's Info.plist.
    static let mactivityReport = UTType(exportedAs: "app.mactivity.report", conformingTo: .json)
}

/// Compare two Macs (1.6): this Mac's report saved as a file, and another Mac's opened beside
/// this one over the same span.
@MainActor
@Observable
public final class CompareMacsModel {
    var isPresented = false
    var exporting = false
    var importing = false
    var days = 30
    private(set) var other: MacProfile?
    private(set) var this: MacProfile?
    private(set) var document: MacReportDocument?
    var problem: String?

    public init() {}

    /// Already read: render tests.
    init(this: MacProfile, other: MacProfile) {
        self.this = this
        self.other = other
        isPresented = true
    }

    /// This Mac over the span, read from History.
    static func profile(_ services: AppServices, days: Int, end: Date = Date()) async -> MacProfile {
        let inputs = await NextMacLoader.inputs(services, days: days, end: end)
        let start = end.addingTimeInterval(-Double(days) * 86400)
        let daily = services.history as? any DailyHistoryStore
        let written = await (try? daily?.systemTotal(metrics: [.diskWrite], from: start, to: end)) ?? 0
        let downloaded = await (try? daily?.systemTotal(metrics: [.netIn], from: start, to: end)) ?? 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacProfile(
            name: Host.current().localizedName ?? MacModel.name(), model: MacModel.name(), chip: MacModel.chip(),
            memory: inputs.installedMemory, disk: inputs.diskCapacity, cores: inputs.performanceCores,
            system: "macOS \(version.majorVersion).\(version.minorVersion)", hasBattery: inputs.hasBattery,
            days: days, start: start, end: end,
            figures: .from(inputs, written: written ?? 0, downloaded: downloaded ?? 0)
        )
    }

    /// Reads this Mac's report, then asks where to save it.
    func export(_ services: AppServices) async {
        document = await MacReportDocument(profile: Self.profile(services, days: days))
        exporting = true
    }

    /// Opens another Mac's report and reads this Mac over the same number of days. Also for a
    /// report double-clicked in Finder.
    public func open(_ url: URL, services: AppServices) async {
        let reading = url.startAccessingSecurityScopedResource()
        defer {
            if reading {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        guard size <= MacProfile.largestFile, let data = try? Data(contentsOf: url), let profile = MacProfile.decode(data) else {
            problem = String(localized: "That file isn't a Mactivity report this version can read.", bundle: .strings)
            return
        }
        other = profile
        this = await Self.profile(services, days: profile.days)
        isPresented = true
    }
}

/// The report as a document for the save panel.
struct MacReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.mactivityReport]
    let profile: MacProfile

    init(profile: MacProfile) {
        self.profile = profile
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let profile = MacProfile.decode(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.profile = profile
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(regularFileWithContents: profile.encoded())
    }
}

/// One line of the comparison: what, this Mac's figure, the other's, and which is higher.
struct MacComparisonRow: Hashable, Identifiable {
    enum Side {
        case this, other
    }

    let title: String
    let this: String
    let other: String
    /// Marked when the two differ by more than a fifth.
    let higher: Side?

    var id: String {
        title
    }

    /// Pure: the figures side by side.
    static func rows(_ this: MacProfile, _ other: MacProfile) -> [MacComparisonRow] {
        let a = this.figures
        let b = other.figures
        func row(_ title: String, _ x: Double, _ y: Double, _ format: (Double) -> String) -> MacComparisonRow {
            let higher: Side? = max(x, y) > 0 && abs(x - y) / max(x, y) > 0.2 ? (x > y ? .this : .other) : nil
            return MacComparisonRow(title: title, this: format(x), other: format(y), higher: higher)
        }
        let percent: (Double) -> String = { Formatters.percent($0) }
        let memory: (Double) -> String = { Formatters.memory(UInt64(min(max(0, $0), 1e18))) }
        let bytes: (Double) -> String = { Formatters.bytes($0) }
        var rows = [
            row(String(localized: "Processor, average", bundle: .strings), a.cpuAverage, b.cpuAverage, percent),
            row(String(localized: "Processor, busiest tenth", bundle: .strings), a.cpuBusy, b.cpuBusy, percent),
            row(String(localized: "Memory used, average", bundle: .strings), a.memoryAverage, b.memoryAverage, memory),
            row(String(localized: "Memory used, peak", bundle: .strings), a.memoryPeak, b.memoryPeak, memory),
            row(String(localized: "Memory pressure", bundle: .strings), a.pressureAverage, b.pressureAverage, percent),
            row(String(localized: "Swap", bundle: .strings), a.swapAverage, b.swapAverage, memory),
            row(String(localized: "Graphics", bundle: .strings), a.gpuAverage, b.gpuAverage, percent),
            row(String(localized: "Slowed down to cool", bundle: .strings), a.hotShare * 100, b.hotShare * 100, percent),
            row(String(localized: "Written to disk, a day", bundle: .strings), a.writtenPerDay, b.writtenPerDay, bytes),
            row(String(localized: "Downloaded, a day", bundle: .strings), a.downloadedPerDay, b.downloadedPerDay, bytes),
        ]
        if let x = a.onBatteryShare, let y = b.onBatteryShare {
            rows.append(row(String(localized: "On battery", bundle: .strings), x * 100, y * 100, percent))
        }
        return rows
    }
}

/// The two Macs side by side.
struct CompareMacsSheet: View {
    @Bindable var model: CompareMacsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if let this = model.this, let other = model.other {
                Text("Two Macs, the last \(other.days) days each", bundle: .strings, comment: "Compare Macs: sheet title")
                    .font(Tokens.Typography.headline)
                Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.s) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        header(this, isThis: true)
                        header(other, isThis: false)
                    }
                    Divider().gridCellColumns(3)
                    ForEach(MacComparisonRow.rows(this, other)) { row in
                        GridRow {
                            Text(row.title).foregroundStyle(.secondary)
                            figure(row.this, emphasized: row.higher == .this)
                            figure(row.other, emphasized: row.higher == .other)
                        }
                    }
                    Divider().gridCellColumns(3)
                    GridRow {
                        Text("Busiest apps", bundle: .strings).foregroundStyle(.secondary)
                        Text(this.figures.cpuApps.formatted(.list(type: .and)))
                        Text(other.figures.cpuApps.formatted(.list(type: .and)))
                    }
                    .font(Tokens.Typography.secondary)
                }
                Text("Bold: higher by more than a fifth. The report came as a file; nothing was uploaded.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 640)
    }

    private func header(_ profile: MacProfile, isThis: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
            Text(isThis ? String(localized: "This Mac", bundle: .strings) : profile.name)
                .font(Tokens.Typography.rowTitle)
                .lineLimit(1)
            Text(verbatim: "\(profile.model) · \(profile.chip) · \(Formatters.memory(profile.memory))")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func figure(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(emphasized ? .semibold : .regular)
    }
}

/// On History: save this Mac's report, or open another Mac's.
struct CompareMacsCard: View {
    let services: AppServices
    @Bindable var model: CompareMacsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .foregroundStyle(Tokens.SidebarTint.history)
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                Text("Compare two Macs", bundle: .strings).font(Tokens.Typography.cardTitle)
                Text("Save this Mac's report, open it in Mactivity on another Mac, and see the two side by side.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Save Report…", bundle: .strings, comment: "Compare Macs: saves this Mac's report file")) {
                Task { await model.export(services) }
            }
            Button(String(localized: "Open Report…", bundle: .strings, comment: "Compare Macs: opens another Mac's report file")) {
                model.importing = true
            }
        }
        .cardStyle()
        .fileExporter(
            isPresented: $model.exporting, document: model.document, contentType: .mactivityReport,
            defaultFilename: (Host.current().localizedName ?? "Mac") + " " + Date().formatted(.iso8601.year().month().day())
        ) { _ in }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.mactivityReport, .json]) { result in
            if case let .success(url) = result {
                Task { await model.open(url, services: services) }
            }
        }
        .sheet(isPresented: $model.isPresented) { CompareMacsSheet(model: model) }
        .alert(model.problem ?? "", isPresented: Binding(get: { model.problem != nil }, set: {
            if !$0 {
                model.problem = nil
            }
        })) {
            Button(String(localized: "OK", bundle: .strings)) {}
        }
    }
}
