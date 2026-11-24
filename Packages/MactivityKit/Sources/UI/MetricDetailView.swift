import Core
import SwiftUI

/// One metric tab: headline, secondary figures, history strip, app list (spec 4.3).
struct MetricDetailView: View {
    let tab: MetricTab
    let services: AppServices
    let range: HistoryRange
    let search: String
    /// The Battery tab's list: nil for the live Energy Impact list, or a span of battery use.
    @State private var batterySpan: BatteryUseList.Span?

    /// `batterySpan` opens the Battery tab on a span of battery use: render tests.
    init(tab: MetricTab, services: AppServices, range: HistoryRange, search: String, batterySpan: BatteryUseList.Span? = nil) {
        self.tab = tab
        self.services = services
        self.range = range
        self.search = search
        _batterySpan = State(initialValue: batterySpan)
    }

    private var batterySpanPicker: some View {
        Picker(
            String(localized: "Show", bundle: .strings, comment: "Battery tab: live list or battery use"),
            selection: $batterySpan
        ) {
            Text("Now", bundle: .strings, comment: "Battery tab: the live list").tag(BatteryUseList.Span?.none)
            ForEach(BatteryUseList.Span.offered(onBattery: isOnBattery)) { Text($0.title(range: range)).tag(Optional($0)) }
        }
        .labelsHidden()
    }

    private var isOnBattery: Bool {
        services.metrics.snapshot?.system.battery?.source == .battery
    }

    /// The scroll view's height and the cards' above the list: the list takes what's left, and
    /// the page scrolls once that's under the list's minimum (D-174).
    @State private var visibleHeight: CGFloat = 0
    @State private var cardsHeight: CGFloat = 0
    /// The page's width inside its padding: where the figures go (D-176).
    @State private var pageWidth: CGFloat = 0

    private var headlineBesideFigures: Bool {
        // Battery may have the Accessories card beside its figures: two columns and a narrow card.
        let figures = tab == .battery
            ? Tokens.Layout.figuresTwoColumnMinWidth + Tokens.Spacing.gridGutter + Tokens.Layout.accessoriesCardNarrowWidth
            : Tokens.Layout.figuresThreeColumnMinWidth
        // Stacked until the width is known: starting wide made a narrow window grow to fit (D-176).
        return pageWidth >= Tokens.Layout.headlineCardWidth + Tokens.Spacing.gridGutter + figures
    }

    var body: some View {
        let metrics = services.metrics
        // A page taller than the window used to push itself and the sidebar up under the title
        // bar (D-072, D-174). Now it scrolls: in a tall window the list fills the rest exactly and
        // nothing moves; in a short one the list keeps a useful height and the page scrolls.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
                cards(metrics)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                list(metrics)
                    .frame(height: listHeight)
                extras
            }
            .padding(Tokens.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
        .overlay(alignment: .bottom) {
            if let toast = services.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: services.toast)
        .confirmedActionDialog(services.confirmedAction)
    }

    /// Below the app list, a scroll away (D-236): the list fills the window as it always did,
    /// and these don't push it down or move it as they load.
    @ViewBuilder private var extras: some View {
        if tab == .cpu {
            SignaturesCard(model: services.signatures, metrics: services.metrics)
        }
        if tab == .battery, services.metrics.hardware.hasBattery {
            BatteryTemperatureCard(services: services, range: range)
            if let store = services.history as? any ChargerHistoryStore {
                ChargersComparedCard(store: store, generation: services.historyGeneration)
            }
        }
        if tab == .network {
            DataBudgetCard(model: services.dataBudget, services: services)
            NetworkHistoryCard(model: services.networkHistory, services: services)
            WiFiChannelsCard(model: services.wifiChannels)
            OpenPortsCard(model: services.openPorts, services: services)
        }
        if tab == .disk {
            SSDWearCard(services: services)
            ExternalDrivesCard(model: services.mountedDrives)
            NetworkDrivesCard(model: services.mountedDrives)
        }
    }

    private var listHeight: CGFloat {
        max(Tokens.Layout.appListMinHeight, visibleHeight - cardsHeight - Tokens.Spacing.gridGutter - 2 * Tokens.Spacing.l)
    }

    /// Everything above the app list.
    private func cards(_ metrics: LiveMetrics) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            // Side by side when the page is wide enough, the figures under the headline when it
            // isn't (D-174). Decided by width alone: measuring the content flipped the layout
            // whenever a live figure got a digit longer (D-176).
            Group {
                if headlineBesideFigures {
                    HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                        HeadlineCard(tab, metrics: metrics)
                            .frame(width: Tokens.Layout.headlineCardWidth)
                        LiveSecondaryFigures(tab: tab, metrics: metrics, history: services.history)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
                        HeadlineCard(tab, metrics: metrics)
                        LiveSecondaryFigures(tab: tab, metrics: metrics, history: services.history)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            HistoryStrip(tab: tab, range: range, services: services, threshold: threshold)
                .equatable()
                .frame(height: Tokens.Layout.historyStripHeight)
            if tab == .battery {
                SleepBlockersBanner(source: services.sleepBlockers) { services.navigation.showHistory(.sleep) }
            }
            if tab == .disk {
                DiskActivityCard(services: services)
                DriveHealthCard(services: services)
            }
            if tab == .network {
                HotspotCard(model: services.hotspot) { services.appHistory.open($0) }
                ConnectionCard(model: services.networkDetails)
                NetworkInterfacesCard(model: services.networkInterfaces)
            }
        }
    }

    /// The list's title row and the list.
    private func list(_ metrics: LiveMetrics) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            // One line at a fixed height: the note (Network, GPU) truncates rather than wrap,
            // so the list starts at the same place on every tab.
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Group {
                    if tab == .battery, batterySpan != nil {
                        Text(
                            "Energy use by app",
                            bundle: .strings,
                            comment: "Battery tab list title over the page's range: share of battery, or of energy when plugged in"
                        )
                    } else if tab == .battery {
                        Text("Energy Impact by app", bundle: .strings)
                            .help(HistoryStrip.energyImpactHelp)
                    } else {
                        Text("Apps", bundle: .strings, comment: "App list title")
                    }
                }
                .font(Tokens.Typography.cardTitle)
                .lineLimit(1)
                // Ahead of the note, but it truncates too rather than widen a narrow window (D-174).
                .layoutPriority(1)
                if !(tab == .battery && batterySpan != nil) {
                    AppListNote(tab: tab, metrics: metrics)
                }
                // Keeps the Now / range / Since unplugged switch on the right whichever is showing (D-112, D-258).
                Spacer(minLength: 0)
                // Energy use by app (D-100, D-114) takes the list's place rather than adding
                // height. On any Mac: without a battery, it's each app's share of energy.
                if tab == .battery {
                    // Segments while they fit; four long ones (Since unplugged, in German) become a menu.
                    ViewThatFits(in: .horizontal) {
                        batterySpanPicker.pickerStyle(.segmented).fixedSize()
                        batterySpanPicker.pickerStyle(.menu).fixedSize()
                    }
                    .onChange(of: isOnBattery) { _, onBattery in
                        if !onBattery, batterySpan == .sinceUnplugged {
                            batterySpan = .range
                        }
                    }
                }
            }
            .frame(height: Tokens.Layout.cardHeaderHeight)
            Group {
                if tab == .battery, let span = batterySpan {
                    BatteryUseList(services: services, span: span, range: range)
                } else {
                    AppListView(
                        data: metrics.appList,
                        metric: tab.appMetric,
                        search: search,
                        highlightedAppID: services.navigation.highlightedAppID,
                        services: services
                    )
                }
            }
            .clipShape(Tokens.Shapes.card)
        }
    }

    /// The alert rule's line, where a rule watches this tab's metric.
    private var threshold: Double? {
        let settings = services.alertSettings
        switch tab {
        case .cpu: return settings.settings(for: .highCPU).isEnabled ? settings.settings(for: .highCPU).threshold : nil
        case .disk: return settings.settings(for: .heavyDisk).isEnabled ? settings.settings(for: .heavyDisk).threshold : nil
        case .network: return settings.settings(for: .heavyNetwork).isEnabled ? settings.settings(for: .heavyNetwork).threshold : nil
        default: return nil
        }
    }
}

/// The note beside the app list's title (Network, GPU), read from the snapshot in its own view.
private struct AppListNote: View {
    let tab: MetricTab
    let metrics: LiveMetrics

    var body: some View {
        if let note = metrics.snapshot.flatMap(tab.appListNote) {
            Text(note)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(note)
        }
    }
}

#Preview("CPU tab") {
    MetricDetailView(tab: .cpu, services: .preview(), range: .h24, search: "")
        .frame(width: 900, height: 700)
}
