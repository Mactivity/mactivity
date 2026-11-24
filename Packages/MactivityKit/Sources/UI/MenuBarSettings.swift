import SwiftUI

/// Settings → Menu Bar: the item's mode with a live preview, then what that mode shows.
struct MenuBarSettings: View {
    let metrics: LiveMetrics

    /// No Battery on a Mac without one, as the Overview rows below (D-197): it would read "–" forever.
    private var available: [MenuBarMetric] {
        MenuBarMetric.allCases.filter { $0 != .battery || metrics.hardware.hasBattery }
    }

    @AppStorage(PreferenceKey.menuBarMode) private var mode: MenuBarMode = .icon
    @AppStorage(PreferenceKey.menuBarMetric) private var metric: MenuBarMetric = .cpu
    @AppStorage(PreferenceKey.menuBarStackedMetrics) private var stackedRaw = MenuBarMetric.stackedDefault
    @AppStorage(PreferenceKey.menuBarShowsGlyph) private var showsGlyph = true
    @AppStorage(PreferenceKey.menuBarGraphShowsValue) private var graphShowsValue = true
    @AppStorage(PreferenceKey.overviewHiddenRows) private var hiddenRowsRaw = ""
    @AppStorage(PreferenceKey.compactLayout) private var layout = CompactLayout.standard
    @StoredFigureChoices private var choices

    private var stacked: [MenuBarMetric] {
        MenuBarMetric.decodeList(stackedRaw)
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Menu bar item", bundle: .strings), selection: $mode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(String(localized: "Preview", bundle: .strings, comment: "A live preview of the menu bar item")) {
                    MenuBarLabel(
                        metrics: metrics, mode: mode, metric: metric, stacked: stacked,
                        showsGlyph: showsGlyph, graphShowsValue: graphShowsValue, choices: choices
                    )
                    // LabeledContent dims its value; the menu bar draws the item in full.
                    .foregroundStyle(.primary)
                    .frame(height: Tokens.MenuBarItem.previewHeight)
                    .padding(.horizontal, Tokens.MenuBarItem.previewPadding)
                    .background(Tokens.Surfaces.tag, in: Tokens.Shapes.tag)
                }
            } footer: {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(mode.refreshNote)
                    if let cost = mode.idleCostNote {
                        Text(cost)
                    }
                }
                .foregroundStyle(.secondary)
            }

            switch mode {
            case .icon:
                EmptyView()
            case .figure:
                Section {
                    Picker(String(localized: "Metric", bundle: .strings), selection: $metric) {
                        ForEach(available) { Text($0.title).tag($0) }
                    }
                    glyphToggle
                }
            case .graph:
                Section {
                    Picker(String(localized: "Metric", bundle: .strings), selection: graphMetric) {
                        ForEach(MenuBarMetric.graphable) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Show the current figure", bundle: .strings), isOn: $graphShowsValue)
                    glyphToggle
                }
            case .stacked:
                Section {
                    ForEach(available) { item in
                        Toggle(item.title, isOn: stackedBinding(item))
                            .disabled(!stacked.contains(item) && stacked.count >= MenuBarMetric.stackedLimit)
                    }
                    glyphToggle
                } header: {
                    // Which metrics, not what each shows: that's General → Figures (D-196).
                    Text("Metrics", bundle: .strings, comment: "Sidebar section header")
                } footer: {
                    Text("One to four, left to right in this order.", bundle: .strings, comment: "Menu bar: how many metrics stack")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                // In the window's order, which dragging here or there changes (D-241). No Battery
                // row to turn off on a Mac without one.
                ForEach(layout.rows.filter { $0 != .battery || metrics.hardware.hasBattery }) { row in
                    Toggle(row.title, isOn: rowBinding(row))
                        .contextMenu {
                            Button(String(localized: "Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
                                moveRow(row, by: -1)
                            }
                            Button(String(localized: "Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
                                moveRow(row, by: 1)
                            }
                        }
                        .accessibilityAction(named: Text("Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
                            moveRow(row, by: -1)
                        }
                        .accessibilityAction(named: Text("Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
                            moveRow(row, by: 1)
                        }
                }
            } header: {
                Text("Menu bar window", bundle: .strings)
            } footer: {
                Text("The rows on the window's Overview. What each figure shows is in General → Figures.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(layout.sections) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !layout.hiddenSections.contains(section) },
                        set: { layout = layout.showing(section, $0) }
                    ))
                    .contextMenu {
                        Button(String(localized: "Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
                            layout = layout.moving(section, by: -1)
                        }
                        Button(String(localized: "Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
                            layout = layout.moving(section, by: 1)
                        }
                    }
                    .accessibilityAction(named: Text("Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
                        layout = layout.moving(section, by: -1)
                    }
                    .accessibilityAction(named: Text("Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
                        layout = layout.moving(section, by: 1)
                    }
                }
                if !layout.isStandard {
                    Button(String(localized: "Back to the Defaults", bundle: .strings, comment: "Customize: undoes every choice")) {
                        layout = .standard
                    }
                }
            } footer: {
                Text(
                    "Drag rows in the window itself to reorder them, or right-click one here. Right-click a section to move it.",
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The preview ticks every second while this pane is open.
        .onAppear { metrics.setVisible(true, surface: .settings) }
        .onDisappear { metrics.setVisible(false, surface: .settings) }
    }

    private var glyphToggle: some View {
        Toggle(String(localized: "Show the Mactivity symbol", bundle: .strings), isOn: $showsGlyph)
    }

    /// Temperature has no graph; a figure-mode choice of it shows as CPU here, as it draws.
    private var graphMetric: Binding<MenuBarMetric> {
        Binding {
            metric.graphSource
        } set: {
            metric = $0
        }
    }

    private func moveRow(_ row: OverviewRow, by offset: Int) {
        guard let index = layout.rows.firstIndex(of: row), layout.rows.indices.contains(index + offset) else {
            return
        }
        layout.rows.swapAt(index, index + offset)
    }

    private func rowBinding(_ row: OverviewRow) -> Binding<Bool> {
        Binding {
            !OverviewRow.decodeHidden(hiddenRowsRaw).contains(row)
        } set: { isOn in
            var hidden = OverviewRow.decodeHidden(hiddenRowsRaw)
            if isOn {
                hidden.remove(row)
            } else {
                hidden.insert(row)
            }
            hiddenRowsRaw = OverviewRow.encodeHidden(hidden)
        }
    }

    private func stackedBinding(_ item: MenuBarMetric) -> Binding<Bool> {
        Binding {
            stacked.contains(item)
        } set: { isOn in
            stackedRaw = MenuBarMetric.encodeList(MenuBarMetric.toggling(item, on: isOn, in: stacked))
        }
    }
}
