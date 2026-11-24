import Charts
import Core
import SwiftUI

/// Overview (spec 4.3): the headline cards, the donuts, Out of the ordinary and Today so far, in
/// the order the person put them, without the ones they hid (D-241). A tile dragged lifts and
/// follows the pointer while the others make room (D-242); Edit Overview… lists them all.
struct OverviewView: View {
    let services: AppServices

    /// The content's width, for the column counts.
    @State private var width: CGFloat = 0
    @AppStorage(PreferenceKey.overviewLayout) var layout = OverviewLayout.standard
    @State private var editing = false
    /// The drag (D-242): the tile, where its card started, how far it has moved, and the order on
    /// screen while it moves.
    @State var dragging: OverviewTile?
    @State var dragStart: CGRect = .zero
    @State var dragTranslation: CGSize = .zero
    @State var preview: OverviewLayout?
    @State var settling = false
    /// Each tile's card, where it is on the page now.
    @State var frames: [OverviewTile: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    static let space = "overview"

    var body: some View {
        let metrics = services.metrics
        // The donuts follow the 3 s list refresh; until the first one, they wait.
        let tiles = arranged.visible.filter { metrics.appList != nil || !$0.isDonut }
        ScrollView {
            VStack(spacing: Tokens.Spacing.gridGutter) {
                WhatsNewBanner(model: services.whatsNew)
                CheckupLine(services: services) { services.navigation.selection = .checkup }
                    .font(Tokens.Typography.secondary)
                ForEach(Array(OverviewLayout.runs(tiles).enumerated()), id: \.offset) { _, run in
                    if run.count == 1, let wide = run.first, wide.isWide {
                        tile(wide)
                    } else {
                        LazyVGrid(columns: columns(for: run.count), spacing: Tokens.Spacing.gridGutter) {
                            ForEach(run) { tile($0) }
                        }
                    }
                }
                Button(String(localized: "Edit Overview…", bundle: .strings, comment: "Overview: reorder or hide its tiles")) {
                    editing = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(Tokens.Typography.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(Tokens.Spacing.l)
            .overlay(alignment: .topLeading) { lifted }
            .coordinateSpace(.named(Self.space))
        }
        .animation(reduceMotion ? nil : ReorderableStack<OverviewTile, EmptyView>.slide, value: tiles)
        .sheet(isPresented: $editing) {
            OverviewEditor(layout: $layout, hasBattery: metrics.hardware.hasBattery)
        }
    }

    /// One tile: the card, the tab it opens, and the ways to move or hide it.
    private func tile(_ tile: OverviewTile) -> some View {
        Group {
            if let tab = tile.metric ?? Self.opens(tile) {
                tabButton(tab) { content(tile) }
            } else {
                content(tile)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[tile] = $0 }
        // Its place stays open under the lifted card.
        .opacity(tile == dragging ? 0 : 1)
        .highPriorityGesture(drag(tile))
        .contextMenu {
            Button(String(localized: "Move to Top", bundle: .strings, comment: "Overview tile menu")) {
                layout = layout.toTop(tile)
            }
            Button(String(localized: "Hide", bundle: .strings, comment: "Overview tile menu: hides the tile")) {
                layout = layout.showing(tile, false)
            }
            Divider()
            Button(String(localized: "Edit Overview…", bundle: .strings, comment: "Overview: reorder or hide its tiles")) {
                editing = true
            }
        }
    }

    /// The dragged tile's card, above the page, under the pointer.
    @ViewBuilder private var lifted: some View {
        if let dragging {
            content(dragging)
                .frame(width: dragStart.width, height: dragStart.height)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .scaleEffect(settling || reduceMotion ? 1 : 1.03)
                .offset(x: dragStart.minX + dragTranslation.width, y: dragStart.minY + dragTranslation.height)
                .allowsHitTesting(false)
        }
    }

    /// Like the cards above them, the donuts open their tab (D-196).
    private static func opens(_ tile: OverviewTile) -> MetricTab? {
        switch tile {
        case .memoryByType, .memoryByApp: .memory
        case .powerByApp: .battery
        default: nil
        }
    }

    @ViewBuilder private func content(_ tile: OverviewTile) -> some View {
        let metrics = services.metrics
        if let tab = tile.metric {
            HeadlineCard(tab, metrics: metrics, compact: true)
        } else {
            switch tile {
            case .memoryByType: if let slow = metrics.appList {
                    MemoryByTypeCard(memory: slow.memory)
                }
            case .memoryByApp: if let slow = metrics.appList {
                    MemoryByAppCard(apps: slow.apps)
                }
            case .powerByApp: if let slow = metrics.appList {
                    PowerByAppCard(apps: slow.apps)
                }
            // Apps doing much more than usual today (D-198); nothing when none are.
            case .unusual: UnusualCard(services: services)
            // From live to the day so far, and on to Your day (D-194).
            default: TodayCard(services: services)
            }
        }
    }

    private func tabButton(_ tab: MetricTab, @ViewBuilder card: () -> some View) -> some View {
        Button {
            services.navigation.selection = tab.sidebarItem
        } label: {
            card()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(
            "Opens the \(tab.title(hasBattery: services.metrics.hardware.hasBattery)) tab",
            bundle: .strings,
            comment: "Overview card: the tab it opens"
        ))
    }

    private func columns(for items: Int) -> [GridItem] {
        let count = Self.columnCount(width: width, items: items)
        return Array(
            repeating: GridItem(.flexible(), spacing: Tokens.Spacing.gridGutter, alignment: .top),
            count: count
        )
    }

    /// Pure: as many columns as fit cards at least `overviewCardMinWidth` wide, preferring rows
    /// that fill: an adaptive grid put six cards in four columns on a wide window, leaving two holes
    /// (D-109). With tiles hidden (D-241) no count may fill every row, so each count is scored by
    /// its rows (twice) and its empty cells, and the lower wins: eight tiles take three columns
    /// and a short last row, not four rows of two. Before the width is known, 3.
    nonisolated static func columnCount(
        width: CGFloat, items: Int, minimum: CGFloat = Tokens.Layout.overviewCardMinWidth,
        gutter: CGFloat = Tokens.Spacing.gridGutter
    ) -> Int {
        guard width > 0, items > 0 else {
            return min(3, max(1, items))
        }
        let fits = max(1, Int((width + gutter) / (minimum + gutter)))
        func score(_ columns: Int) -> Int {
            let rows = (items + columns - 1) / columns
            return 2 * rows + rows * columns - items
        }
        return (1 ... min(fits, items)).min { score($0) == score($1) ? $0 > $1 : score($0) < score($1) } ?? 1
    }
}

/// One slice of a donut, and its legend row.
struct DonutEntry: Equatable, Identifiable {
    let name: String
    let value: Double
    /// "Other": the sum of everything past the top rows.
    var isRemainder = false
    /// What the entry means, on hover (the memory types).
    var help: String?

    var id: String {
        isRemainder ? "\u{0}other" : name
    }
}

enum DonutEntries {
    /// The largest `limit` entries, then "Other" for the rest. Zero and negative values are left
    /// out. When only one entry is left over, it gets its own row instead of an "Other" of one.
    private static let otherName = String(localized: "Other", bundle: .strings, comment: "Donut slice: everything past the top rows")

    static func top(_ entries: [DonutEntry], limit: Int = Tokens.Layout.donutTopRows) -> [DonutEntry] {
        let sorted = entries
            .filter { $0.value > 0 && $0.value.isFinite }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
        guard sorted.count > limit + 1 else {
            return sorted
        }
        let rest = sorted.dropFirst(max(0, limit)).reduce(0) { $0 + $1.value }
        return Array(sorted.prefix(max(0, limit))) + [DonutEntry(name: otherName, value: rest, isRemainder: true)]
    }
}

/// The donut row: the legend gets its full width first, and the ring takes what's left within
/// `Tokens.Layout.donutRing`. When even the smallest ring leaves too little, names truncate in
/// the middle; values never do.
struct DonutRowLayout: Layout {
    var ring: ClosedRange<CGFloat> = Tokens.Layout.donutRing
    var spacing: CGFloat = Tokens.Spacing.s

    /// The ring's diameter for a row `available` points wide whose legend wants `legend`.
    static func diameter(available: CGFloat, legend: CGFloat, ring: ClosedRange<CGFloat>, spacing: CGFloat) -> CGFloat {
        let left = available - spacing - legend
        return max(0, min(min(max(left, ring.lowerBound), ring.upperBound), available - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return .zero
        }
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let width = max(proposal.width ?? (ring.upperBound + spacing + ideal.width), ring.lowerBound + spacing)
        let diameter = Self.diameter(available: width, legend: ideal.width, ring: ring, spacing: spacing)
        let legend = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - diameter - spacing), height: nil))
        return CGSize(width: width, height: max(ring.upperBound, legend.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else {
            return
        }
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let diameter = Self.diameter(available: bounds.width, legend: ideal.width, ring: ring, spacing: spacing)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: diameter, height: diameter)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + diameter + spacing, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: max(0, bounds.width - diameter - spacing), height: nil)
        )
    }
}

/// A donut with its total in the middle and a legend beside it. Content surface, never glass.
private struct DonutCard: View {
    let title: String
    let symbol: String
    /// The symbol's color: the metric the card breaks down (D-057).
    let tint: Color
    let entries: [DonutEntry]
    /// The figure in the ring's center, and the words under it.
    let total: String
    let totalCaption: String
    /// Slice colors in order; "Other" and "Free" use `seriesRemainder`.
    var colors: [Color] = Tokens.Colors.series
    let format: (Double) -> String

    @Environment(\.colorSchemeContrast) private var contrast

    /// The slices' value name, read by VoiceOver.
    private static let valueAxis = String(localized: "Value", bundle: .strings, comment: "Chart: a donut slice's size")

    var body: some View {
        // The headline cards' spacing, so the two rows of cards line up under their titles.
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CardHeader(title: title, symbol: symbol, status: nil, tint: tint)
            DonutRowLayout {
                ring
                legend
            }
        }
        .cardStyle()
    }

    private var ring: some View {
        Chart(entries) { entry in
            SectorMark(
                angle: .value(Self.valueAxis, entry.value),
                innerRadius: .ratio(Tokens.Layout.donutInnerRatio),
                angularInset: Tokens.Layout.donutSliceGap
            )
            .foregroundStyle(color(entry))
            .cornerRadius(Tokens.Radius.sector)
        }
        .chartLegend(.hidden)
        .overlay {
            // Inside the hole, not the whole ring: a wider total ("648 mW") ran over the slices.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Text(total)
                        .font(Tokens.Typography.donutCenter)
                        .monospacedDigit()
                    Text(totalCaption)
                        .font(Tokens.Typography.donutCenterCaption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(Tokens.Layout.donutCenterMinimumScale)
                .frame(width: min(proxy.size.width, proxy.size.height) * Tokens.Layout.donutLabelWidthRatio)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ForEach(entries) { entry in
                HStack(spacing: Tokens.Spacing.xxs) {
                    Circle()
                        .fill(color(entry))
                        .frame(width: Tokens.Layout.statusDot, height: Tokens.Layout.statusDot)
                    Text(entry.name)
                        .lineLimit(1)
                        .minimumScaleFactor(1 / Customization.shared.figureScale)
                        .truncationMode(.middle)
                    Spacer(minLength: Tokens.Spacing.xs)
                    Text(format(entry.value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(Tokens.Typography.secondary)
                .help(entry.help ?? "")
            }
        }
    }

    private func color(_ entry: DonutEntry) -> Color {
        guard !entry.isRemainder, let index = entries.firstIndex(of: entry), !colors.isEmpty else {
            return Tokens.Colors.seriesRemainder(contrast)
        }
        return colors[index % colors.count]
    }
}

struct MemoryByTypeCard: View {
    let memory: MemoryStats

    private static let app = String(localized: "App", bundle: .strings, comment: "Memory type: app memory")
    private static let wired = String(localized: "Wired", bundle: .strings, comment: "Memory figure: wired memory")
    private static let compressed = String(localized: "Compressed", bundle: .strings, comment: "Memory figure: compressed memory")
    private static let cachedFiles = String(localized: "Cached files", bundle: .strings)
    private static let free = String(
        localized: "memory.free",
        defaultValue: "Free",
        bundle: .strings,
        comment: "Memory type: free memory (agrees with “memory”)"
    )

    var body: some View {
        let free = memory.totalBytes.subtractingClamped(memory.usedBytes + memory.cachedFilesBytes)
        let inUse = memory.totalBytes > 0 ? Double(memory.usedBytes) / Double(memory.totalBytes) * 100 : 0
        // A fixed order (Activity Monitor's), not sorted by size; "Free" is the remainder color.
        DonutCard(
            title: String(localized: "Memory by type", bundle: .strings, comment: "Overview card"),
            symbol: SidebarItem.memory.symbol,
            tint: MetricTab.memory.tint,
            entries: [
                DonutEntry(name: Self.app, value: Double(memory.appBytes), help: FigureHelp.appMemory),
                DonutEntry(name: Self.wired, value: Double(memory.wiredBytes), help: FigureHelp.wired),
                DonutEntry(name: Self.compressed, value: Double(memory.compressedBytes), help: FigureHelp.compressed),
                DonutEntry(name: Self.cachedFiles, value: Double(memory.cachedFilesBytes), help: FigureHelp.cachedFiles),
                DonutEntry(name: Self.free, value: Double(free), isRemainder: true),
            ],
            total: Formatters.percent(inUse),
            totalCaption: String(localized: "in use", bundle: .strings, comment: "Donut center caption under the memory in use percentage"),
            format: { Formatters.memory($0) }
        )
    }
}

struct MemoryByAppCard: View {
    let apps: [AppAggregate]

    var body: some View {
        let entries = apps.map { DonutEntry(name: $0.app.name, value: Double($0.memoryBytes)) }
        DonutCard(
            title: String(localized: "Memory by app", bundle: .strings, comment: "Overview card"),
            symbol: Tokens.Symbols.apps,
            tint: MetricTab.memory.tint,
            entries: DonutEntries.top(entries),
            total: Formatters.memory(entries.reduce(0) { $0 + $1.value }),
            totalCaption: String(localized: "all apps", bundle: .strings, comment: "Donut center caption under the total for all apps"),
            format: { Formatters.memory($0) }
        )
    }
}

struct PowerByAppCard: View {
    let apps: [AppAggregate]

    var body: some View {
        let entries = apps.map { DonutEntry(name: $0.app.name, value: $0.energyMW ?? 0) }
        DonutCard(
            title: String(localized: "Power by app", bundle: .strings, comment: "Overview card"),
            symbol: "bolt",
            tint: MetricTab.battery.tint,
            entries: DonutEntries.top(entries),
            total: Formatters.power(milliwatts: entries.reduce(0) { $0 + max(0, $1.value) }),
            totalCaption: String(localized: "all apps", bundle: .strings, comment: "Donut center caption under the total for all apps"),
            format: { Formatters.power(milliwatts: $0) }
        )
    }
}

extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

#Preview("Overview") {
    OverviewView(services: .preview())
        .frame(width: 1100, height: 720)
}
