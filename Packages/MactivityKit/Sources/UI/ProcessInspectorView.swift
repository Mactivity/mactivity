import Core
import Projects
import SwiftUI

/// The process inspector (expansion E12): overview, parent chain, open files, and network for
/// one PID, refreshed every 2 s while it's on screen. Read-only; Quit and Force Quit go through
/// `AppServices.requestQuit(_:mode:)` and the `ConfirmedAction` path (CLAUDE.md rule 4).
public struct ProcessInspectorView: View {
    private let services: AppServices
    @State private var model: InspectorModel
    @State private var tab: InspectorTab = .overview
    @State private var trail = ProcessTrail()
    private var onDone: (() -> Void)?
    private var attachesConfirmationDialog = true

    public init(pid: Int32, source: any ProcessDetailsSource, services: AppServices) {
        self.init(pid: pid, source: source, services: services, tab: .overview)
    }

    /// Opens on a given tab (render tests).
    init(pid: Int32, source: any ProcessDetailsSource, services: AppServices, tab: InspectorTab) {
        self.services = services
        _model = State(initialValue: InspectorModel(pid: pid, source: source))
        _tab = State(initialValue: tab)
    }

    /// Adds a Done button (Return / Escape), for presenting as a sheet.
    public func onDone(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onDone = action
        return copy
    }

    /// The inspector shows the Quit confirmation itself, which a sheet needs. Pass false when it's
    /// shown inside a view that already has `.confirmedActionDialog` (an inspector pane).
    public func attachesConfirmationDialog(_ attached: Bool) -> Self {
        var copy = self
        copy.attachesConfirmationDialog = attached
        return copy
    }

    public var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(model: model)
                .padding(Tokens.Spacing.m)
            content
            Divider()
            footer
                .padding(Tokens.Spacing.s)
        }
        .frame(
            minWidth: InspectorLayout.minimumSize.width, idealWidth: InspectorLayout.idealSize.width,
            minHeight: InspectorLayout.minimumSize.height, idealHeight: InspectorLayout.idealSize.height
        )
        .task(id: model.pid) { await model.run() }
        // A macOS process only gets figures while someone asks for them (D-086); an open Get Info
        // window does, so its sparklines fill in even with the macOS row collapsed.
        .onAppear { services.metrics.setSystemDetail(true, for: .inspector) }
        .onDisappear { services.metrics.setSystemDetail(false, for: .inspector) }
        // A parent in the chain is a different process: its own trail.
        .onChange(of: model.pid) { trail = ProcessTrail() }
        .onChange(of: services.metrics.snapshot?.at, initial: true) {
            if let snapshot = services.metrics.snapshot {
                trail.add(snapshot, pid: model.pid)
            }
        }
        .modifier(OptionalConfirmationDialog(action: services.confirmedAction, isAttached: attachesConfirmationDialog))
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .exited:
            ContentUnavailableView {
                Label(
                    String(localized: "Process \(String(model.pid)) has exited", bundle: .strings, comment: "The argument is a PID"),
                    systemImage: "xmark.circle"
                )
            } description: {
                Text("It isn't running any more.", bundle: .strings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let details = model.details {
                Picker(String(localized: "Show", bundle: .strings, comment: "Shows a list or a section"), selection: $tab) {
                    Text("Overview", bundle: .strings).tag(InspectorTab.overview)
                    Text("Open Files", bundle: .strings).tag(InspectorTab.files)
                    Text("Network", bundle: .strings).tag(InspectorTab.network)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, Tokens.Spacing.s)
                Group {
                    switch tab {
                    case .overview: InspectorOverview(details: details, model: model, trail: trail)
                    case .files: InspectorFiles(details: details)
                    case .network: InspectorNetwork(details: details, names: model.names)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let reason = model.quitUnavailableReason {
                Text(reason)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Quit…", bundle: .strings)) {
                if let target = model.quitTarget {
                    services.requestQuit(target, mode: .quit)
                }
            }
            .disabled(!model.canQuit)
            Button(String(localized: "Force Quit…", bundle: .strings), role: .destructive) {
                if let target = model.quitTarget {
                    services.requestQuit(target, mode: .forceQuit)
                }
            }
            .disabled(!model.canQuit)
            if let onDone {
                Button(String(localized: "Done", bundle: .strings), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

enum InspectorTab: Hashable {
    case overview, files, network
}

private struct OptionalConfirmationDialog: ViewModifier {
    let action: ConfirmedAction
    let isAttached: Bool

    func body(content: Content) -> some View {
        if isAttached {
            content.confirmedActionDialog(action)
        } else {
            content
        }
    }
}

// MARK: Header

/// Icon, name, PID and owner, the way back after following the parent chain, and why the
/// process can't be read when it can't.
private struct InspectorHeader: View {
    let model: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                ExecutableIcon(path: model.details?.executablePath)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(model.details?.name ?? String(
                        localized: "PID \(String(model.pid))",
                        bundle: .strings,
                        comment: "Process identifier, before the process's name is known"
                    ))
                    .font(Tokens.Typography.cardTitle)
                    .lineLimit(1)
                    HStack(spacing: Tokens.Spacing.xxs) {
                        Text("PID", bundle: .strings, comment: "Process identifier")
                        Text(String(model.pid))
                            .font(Tokens.Typography.codeSecondary)
                        if let details = model.details {
                            Text(verbatim: "·")
                            Text(details.user ?? String(
                                localized: "uid \(String(details.uid))",
                                bundle: .strings,
                                comment: "A Unix user ID, when the user's name is unknown"
                            ))
                            Text(verbatim: "·")
                            Text(
                                "up \(Formatters.duration(.seconds(max(0, details.sampledAt.timeIntervalSince(details.startedAt)))))",
                                bundle: .strings,
                                comment: "How long the process has been running"
                            )
                            .monospacedDigit()
                        }
                    }
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // Beside the name, not above it: a line that came and went with the parent chain
                // moved the whole inspector down and back up.
                if let previous = model.history.last {
                    // A name and a PID: data, not words.
                    let title = "\(previous.name) (\(String(previous.pid)))"
                    Button {
                        model.goBack()
                    } label: {
                        Label(title, systemImage: "chevron.backward")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .font(Tokens.Typography.secondary)
                    .help(Text("Back to \(previous.name)", bundle: .strings, comment: "Help tag: a process's name"))
                }
            }
            if let details = model.details, !details.isReadable, let reason = details.unreadableReason {
                Label(reason, systemImage: "lock.fill")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.s)
                    .background(Tokens.Surfaces.card, in: Tokens.Shapes.card)
            }
        }
    }
}

/// The enclosing app's icon, or the generic executable icon.
private struct ExecutableIcon: View {
    let path: String?

    var body: some View {
        let image = InspectorText.bundlePath(path).map { IconCache.shared.icon(forPath: $0) } ?? IconCache.shared.executableIcon
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: Tokens.IconSize.card, height: Tokens.IconSize.card)
            .accessibilityHidden(true)
    }
}

// MARK: Overview

private struct InspectorOverview: View {
    let details: ProcessDetails
    let model: InspectorModel
    let trail: ProcessTrail

    var body: some View {
        Form {
            // There from the start, with "Measuring…" until two samples are in: a section that
            // appeared after the first sample pushed everything under it down.
            Section(String(localized: "Since this window opened", bundle: .strings)) {
                trailRow(
                    String(localized: "CPU", bundle: .strings),
                    points: trail.cpu,
                    domain: 0 ... 100,
                    tint: MetricTab.cpu.tint,
                    unit: .percent
                )
                trailRow(
                    String(localized: "Memory", bundle: .strings),
                    points: trail.memory,
                    domain: nil,
                    tint: MetricTab.memory.tint,
                    unit: .memory
                )
            }
            Section(String(localized: "Process", bundle: .strings)) {
                LabeledContent(String(localized: "PID", bundle: .strings, comment: "Process identifier")) {
                    Text(String(details.pid)).font(Tokens.Typography.code)
                }
                LabeledContent(String(localized: "User", bundle: .strings)) {
                    Text(verbatim: "\(details.user ?? "–") (\(String(details.uid)))")
                }
                LabeledContent(String(localized: "Started", bundle: .strings, comment: "When the process started")) {
                    Text(details.startedAt.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                }
                LabeledContent(String(localized: "Threads", bundle: .strings)) {
                    Text(details.threadCount.map(String.init) ?? "–").monospacedDigit()
                }
                LabeledContent(String(localized: "Memory", bundle: .strings)) {
                    Text(details.footprintBytes.map { Formatters.memory($0) } ?? "–").monospacedDigit()
                }
                LabeledContent(String(localized: "CPU time", bundle: .strings)) {
                    Text(details.cpuTime.map(Formatters.duration) ?? "–").monospacedDigit()
                }
            }
            Section(String(localized: "Paths", bundle: .strings)) {
                PathRow(title: String(localized: "Executable", bundle: .strings), path: details.executablePath)
                PathRow(title: String(localized: "Working directory", bundle: .strings), path: details.workingDirectory)
            }
            if details.isReadable {
                Section(String(localized: "Command line", bundle: .strings)) {
                    HStack(alignment: .top) {
                        Text(details.commandLine.isEmpty ? "–" : details.commandLine)
                            .font(Tokens.Typography.code)
                            .lineLimit(InspectorLayout.commandLineLines)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(details.commandLine)
                        Button {
                            InspectorText.copy(details.commandLine)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Copy command line", bundle: .strings))
                        .accessibilityLabel(Text("Copy command line", bundle: .strings))
                    }
                }
            }
            Section(String(localized: "Parent chain", bundle: .strings)) {
                if details.parentChain.isEmpty {
                    Text("launchd is the first process; it has no parent.", bundle: .strings)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(details.parentChain) { ancestor in
                        Button {
                            model.inspect(ancestor.pid)
                        } label: {
                            LabeledContent {
                                HStack(spacing: Tokens.Spacing.xs) {
                                    Text(String(ancestor.pid))
                                        .font(Tokens.Typography.code)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.forward")
                                        .foregroundStyle(.tertiary)
                                }
                            } label: {
                                Text(ancestor.name)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(Text("Inspect \(ancestor.name)", bundle: .strings, comment: "Help tag: a process's name"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func trailRow(
        _ title: String,
        points: [LiveMetrics.Point],
        domain: ClosedRange<Double>?,
        tint: Color,
        unit: SparklineUnit
    ) -> some View {
        LabeledContent(title) {
            Sparkline(points: points, domain: domain, tint: tint, unit: unit)
                .overlay {
                    if points.count < 2 {
                        Group {
                            if trail.isUnsampled {
                                Text(
                                    "Not sampled",
                                    bundle: .strings,
                                    comment: "Inspector: Mactivity isn't sampling this process's CPU and memory"
                                )
                            } else {
                                Text("Measuring…", bundle: .strings)
                            }
                        }
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(width: InspectorLayout.trailWidth, height: InspectorLayout.trailHeight)
                // The form lines the label's baseline up with this; near the middle, the label
                // sits centered on the sparkline instead of level with its top.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
}

/// A labelled path on its own line, monospaced and selectable, with Show in Finder.
private struct PathRow: View {
    let title: String
    let path: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                Text(title)
                Text(path.map(InspectorText.abbreviated) ?? String(localized: "Not readable", bundle: .strings))
                    .font(Tokens.Typography.code)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .help(path ?? "")
            }
            Spacer()
            if let path, InspectorText.canReveal(path) {
                RevealButton(path: path)
            }
        }
    }
}

struct RevealButton: View {
    let path: String

    var body: some View {
        Button {
            InspectorText.reveal(path)
        } label: {
            Image(systemName: Tokens.Symbols.revealInFinder)
        }
        .buttonStyle(.borderless)
        .help(Text("Show in Finder", bundle: .strings))
        .accessibilityLabel(Text("Show in Finder", bundle: .strings))
    }
}

#Preview("Inspector: dev server") {
    ProcessInspectorView(pid: 4101, source: SimulatedProcessDetailsSource(), services: .preview())
}

#Preview("Inspector: launchd") {
    ProcessInspectorView(pid: 1, source: SimulatedProcessDetailsSource(), services: .preview())
}
