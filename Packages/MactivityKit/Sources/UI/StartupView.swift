import Core
import Startup
import SwiftUI

/// Startup tokens, added beside the shared ones rather than editing them.
extension Tokens {
    enum Startup {
        /// Flags are amber, never red (spec 10.2), darkened on light surfaces so the words read.
        static func flag(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
            Colors.strainText(scheme, contrast)
        }

        static func flagFill(_ contrast: ColorSchemeContrast) -> Color {
            Colors.strainFill(contrast)
        }

        static let running = Colors.status(.normal)
        static let inspectorWidth = (min: CGFloat(260), ideal: CGFloat(290), max: CGFloat(420))
        static let labelWidth: CGFloat = 80
    }
}

/// Startup tab (expansion E4): what starts with the Mac, grouped by the app that put it there,
/// with an inspector and the actions the public APIs allow.
public struct StartupView: View {
    @Bindable private var model: StartupModel
    /// Opens when a row is selected; the toolbar button and the column's own edge close it.
    @State private var showsInspector = false
    /// For the after-startup card (D-171); nil in previews and tests of the table alone.
    private let services: AppServices?
    @State private var startupReport: StartupReport?

    public init(model: StartupModel, services: AppServices? = nil) {
        self.init(model: model, services: services, report: nil)
    }

    /// With a report already measured: render tests and screenshots.
    init(model: StartupModel, services: AppServices?, report: StartupReport?) {
        self.model = model
        self.services = services
        _startupReport = State(initialValue: report)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            StartupHeader(model: model)
            if let startupReport {
                StartupCostCard(
                    report: startupReport,
                    startsAtLogin: Set(model.items.compactMap(\.owner.bundleID))
                ) { app in
                    services?.appHistory.open(app)
                }
            }
            if isEmpty, let error = model.loadError {
                ContentUnavailableView {
                    Label(String(localized: "Couldn't read startup items", bundle: .strings), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(String(localized: "Try Again", bundle: .strings)) {
                        Task { await model.refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing found", bundle: .strings), systemImage: "power")
                } description: {
                    Text("No login items, agents, or daemons outside macOS.", bundle: .strings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No minimum width: with the inspector open, one made SwiftUI widen the window past
                // its size instead of narrowing the table (the D-072 kind of bug, sideways).
                StartupTable(model: model)
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(
                        rows: CGFloat(model.groups.reduce(0) { $0 + $1.items.count }) * TableFit.oneLineRow,
                        sections: model.groups.count
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Tokens.Spacing.l)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: model.toast)
        .inspector(isPresented: inspectorPresented) {
            StartupDetail(item: model.selectedItem, model: model)
                .inspectorColumnWidth(
                    min: Tokens.Startup.inspectorWidth.min,
                    ideal: Tokens.Startup.inspectorWidth.ideal,
                    max: Tokens.Startup.inspectorWidth.max
                )
        }
        .toolbar {
            if !isEmpty {
                ToolbarItem {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label(
                            showsInspector
                                ? String(localized: "Hide Inspector", bundle: .strings)
                                : String(localized: "Show Inspector", bundle: .strings),
                            systemImage: "sidebar.trailing"
                        )
                    }
                    .help(
                        showsInspector
                            ? Text("Hide the selected item's details", bundle: .strings)
                            : Text("Show the selected item's details", bundle: .strings)
                    )
                }
            }
        }
        .onChange(of: model.selection, initial: true) { _, selection in
            if selection != nil {
                showsInspector = true
            }
        }
        .task {
            await model.refresh()
            if let services, startupReport == nil {
                startupReport = await StartupReport.load(services)
            }
        }
        .confirmationDialog(
            model.pendingDisable.map {
                String(localized: "Disable “\($0.name)”?", bundle: .strings, comment: "Confirmation title: a login item's name")
            } ?? "",
            isPresented: Binding(get: { model.pendingDisable != nil }, set: {
                if !$0 {
                    model.pendingDisable = nil
                }
            }),
            titleVisibility: .visible,
            presenting: model.pendingDisable
        ) { _ in
            Button(String(localized: "Disable", bundle: .strings, comment: "Confirms turning off a launch agent")) {
                // Accept now, before the dialog's dismissal clears the pending item.
                if let item = model.acceptDisable() {
                    Task { await model.disable(item) }
                }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {
                model.pendingDisable = nil
            }
        } message: { _ in
            Text(StartupCopy.disableMessage)
        }
    }

    /// Nothing to list, so nothing to inspect.
    private var isEmpty: Bool {
        model.hasLoaded && model.items.isEmpty
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(get: { showsInspector && !isEmpty }, set: { showsInspector = $0 })
    }
}

// MARK: - Table

private struct StartupTable: View {
    @Bindable var model: StartupModel

    var body: some View {
        Table(of: StartupItem.self, selection: $model.selection) {
            // Flags ride along with the name: a separate column would push Status off a 1100 pt window.
            TableColumn(Text("Item", bundle: .strings, comment: "Column: a login item, agent, or daemon")) { item in
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.startsWithMac ? .primary : .secondary)
                        .help(item.label)
                    ForEach(item.flags, id: \.kind) { flag in
                        FlagTag(flag: flag)
                            .layoutPriority(1)
                    }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn(Text("Kind", bundle: .strings)) { item in
                Text(item.kind.title)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 72)
            TableColumn(Text("Schedule", bundle: .strings)) { item in
                Text(StartupText.schedule(item.schedule, kind: item.kind))
                    .lineLimit(1)
                    .help(StartupText.schedule(item.schedule, kind: item.kind))
            }
            .width(min: 80, ideal: 100)
            TableColumn(Text("Status", bundle: .strings, comment: "Table column: a startup item's status (Running, Off…)")) { item in
                RunningLabel(item: item)
            }
            .width(min: 76, ideal: 84)
        } rows: {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        TableRow(item)
                            .contextMenu { StartupItemMenu(item: item, model: model) }
                    }
                } header: {
                    OwnerHeader(owner: group.owner, count: group.items.count)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct OwnerHeader: View {
    let owner: StartupOwner
    let count: Int

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            AppIconView(owner.identity)
            Text(owner.name)
                .font(Tokens.Typography.rowTitle)
                .foregroundStyle(.primary)
            Text([
                owner.evidence == .missingApp
                    ? String(localized: "not installed", bundle: .strings, comment: "Startup group header: the owning app is gone")
                    : nil,
                String(localized: "\(count) items", bundle: .strings, comment: "Startup group header: how many items the app added"),
            ]
            .compactMap(\.self).joined(separator: " · "))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "● Running", "Not running", "Off", or "—" when a shared executable can't tell.
private struct RunningLabel: View {
    let item: StartupItem

    var body: some View {
        // The dot's space is there on every row, so the words line up down the column.
        StatusDotLabel(
            StartupCopy.stateText(item),
            color: showsDot ? Tokens.Startup.running : nil,
            isProminent: item.isRunning == true
        )
        .help(item.state.title)
        .accessibilityElement(children: .combine)
    }

    private var showsDot: Bool {
        item.isRunning == true && (item.startsWithMac || item.state == .unknown)
    }
}

/// An amber capsule tag.
struct FlagTag: View {
    let flag: StartupFlag

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(flag.title)
            .foregroundStyle(Tokens.Startup.flag(colorScheme, contrast))
            .tagStyle(Tokens.Startup.flagFill(contrast))
            .help(flag.reason)
    }
}

/// Right-click menu and the inspector's buttons share these.
private struct StartupItemMenu: View {
    let item: StartupItem
    let model: StartupModel

    var body: some View {
        Button(String(localized: "Show in Finder", bundle: .strings)) { StartupActions.revealInFinder(item) }
        if item.canDisable {
            Button(String(localized: "Disable…", bundle: .strings)) { model.askToDisable(item) }
        } else if item.canEnable {
            Button(String(localized: "Enable", bundle: .strings)) { Task { await model.enable(item) } }
        }
        Divider()
        Button(String(localized: "Login Items Settings…", bundle: .strings)) { StartupActions.openLoginItemsSettings() }
    }
}

// MARK: - Inspector

/// The selected item in the inspector column. The column brings its own surface, so no card.
private struct StartupDetail: View {
    let item: StartupItem?
    let model: StartupModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let item {
            ScrollView {
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.m)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ContentUnavailableView(
                String(localized: "Select an item", bundle: .strings),
                systemImage: "sidebar.trailing",
                description: Text("Its plist, its program, and what you can do about it show here.", bundle: .strings)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                AppIconView(item.owner.identity, size: Tokens.IconSize.card)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs / 2) {
                    Text(item.name)
                        .font(Tokens.Typography.cardTitle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(item.owner.name)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(item.flags, id: \.kind) { flag in
                Label(flag.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Startup.flag(colorScheme, contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Actions before the details, so they're never below the fold.
            actions(item)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.s, verticalSpacing: Tokens.Spacing.xxs) {
                ForEach(facts(item), id: \.label) { fact in
                    GridRow {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .frame(width: Tokens.Startup.labelWidth, alignment: .leading)
                        Text(fact.value)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Tokens.Typography.secondary)
            ForEach(codeFields(item), id: \.label) { field in
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs / 2) {
                    Text(field.label)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(Tokens.Typography.codeSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func actions(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                Button(String(localized: "Show in Finder", bundle: .strings)) { StartupActions.revealInFinder(item) }
                if item.canDisable {
                    Button(String(localized: "Disable…", bundle: .strings)) { model.askToDisable(item) }
                } else if item.canEnable {
                    Button(String(localized: "Enable", bundle: .strings)) { Task { await model.enable(item) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(String(localized: "Login Items Settings…", bundle: .strings)) { StartupActions.openLoginItemsSettings() }
                        .help(Text("Opens System Settings → General → Login Items & Extensions.", bundle: .strings))
                }
            }
            Text(note(item))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ item: StartupItem) -> String {
        if item.canDisable {
            return String(localized: "Disabling takes effect at your next login.", bundle: .strings)
        }
        if item.canEnable {
            return String(
                localized: "Enable moves it back to your LaunchAgents folder. It starts again at your next login.",
                bundle: .strings
            )
        }
        return item.location == .appBundle || item.location == .serviceManagement ? StartupCopy.helperNote : StartupCopy.adminNote
    }

    private struct Field {
        let label: String
        let value: String
    }

    private func facts(_ item: StartupItem) -> [Field] {
        let running = item.isRunning.map { $0 ? Self.yes : Self.no }
            ?? String(localized: "Can't tell: shared program", bundle: .strings)
        var facts = [
            Field(label: String(localized: "Kind", bundle: .strings), value: item.kind.title),
            Field(label: String(localized: "Schedule", bundle: .strings), value: StartupText.schedule(item.schedule, kind: item.kind)),
            Field(label: String(localized: "State", bundle: .strings), value: item.state.title),
            Field(label: String(localized: "Running", bundle: .strings), value: running),
            Field(label: String(localized: "Matched by", bundle: .strings), value: StartupCopy.evidence(item.owner)),
        ]
        // RunAtLoad and KeepAlive are the plist's own key names, so they stay as they are.
        if let plist = item.plist {
            facts.append(Field(label: "RunAtLoad", value: plist.runAtLoad ? Self.yes : Self.no))
            facts.append(Field(label: "KeepAlive", value: keepAlive(plist.keepAlive)))
            if !plist.onDemandTriggers.isEmpty {
                facts.append(Field(label: StartupCopy.startedOnDemandBy, value: plist.onDemandTriggers.joined(separator: ", ")))
            }
        }
        if let status = item.loginItemsStatus {
            facts.append(Field(label: String(localized: "Login Items", bundle: .strings), value: loginItems(status)))
        }
        return facts
    }

    /// Paths and identifiers, in monospace on their own lines so they wrap at slashes.
    private func codeFields(_ item: StartupItem) -> [Field] {
        var fields = [
            Field(label: String(localized: "Label", bundle: .strings, comment: "Inspector row: the launchd label"), value: item.label),
        ]
        if let path = item.executablePath ?? item.plist?.declaredExecutable {
            fields.append(Field(label: String(localized: "Program", bundle: .strings), value: path))
        }
        if !item.arguments.isEmpty {
            fields.append(Field(label: String(localized: "Arguments", bundle: .strings), value: item.arguments.joined(separator: " ")))
        }
        // The plist's own key name.
        if let identifiers = item.plist?.associatedBundleIdentifiers, !identifiers.isEmpty {
            fields.append(Field(label: "AssociatedBundleIdentifiers", value: identifiers.joined(separator: "\n")))
        }
        let pathLabel = item.plistPath == nil
            ? String(localized: "Path", bundle: .strings)
            : String(localized: "Plist", bundle: .strings, comment: "Inspector row: the property list file's path")
        fields.append(Field(label: pathLabel, value: item.revealPath))
        return fields
    }

    private static let yes = String(localized: "Yes", bundle: .strings)
    private static let no = String(localized: "No", bundle: .strings)

    private func keepAlive(_ value: KeepAlive) -> String {
        switch value {
        case .off: Self.no
        case .always: String(localized: "Always", bundle: .strings, comment: "KeepAlive value: launchd always restarts it")
        case let .conditions(keys):
            String(
                localized: "When \(keys.joined(separator: ", "))",
                bundle: .strings,
                comment: "KeepAlive value: the plist's condition keys, verbatim"
            )
        }
    }

    private func loginItems(_ status: LoginItemsStatus) -> String {
        switch status {
        case .enabled: String(localized: "Allowed", bundle: .strings, comment: "Login Items status")
        case .requiresApproval: String(localized: "Turned off", bundle: .strings, comment: "Login Items status")
        case .notRegistered: String(localized: "Not registered", bundle: .strings, comment: "Login Items status")
        case .notFound: String(localized: "Not listed", bundle: .strings, comment: "Login Items status")
        }
    }
}

extension StartupOwner {
    /// For `AppIconView`: the app's own icon, or the executable icon for Unknown.
    var identity: AppIdentity {
        if let bundlePath {
            return AppIdentity(id: id, name: name, bundleID: bundleID, iconKey: bundlePath, kind: .app)
        }
        return .other(executableName: name)
    }
}

#Preview("Startup") {
    StartupView(model: .preview())
        .frame(width: 1000, height: 640)
}
