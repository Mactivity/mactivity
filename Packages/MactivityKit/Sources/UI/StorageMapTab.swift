import Core
import QuickLook
import Storage
import SwiftUI

/// Map tab: breadcrumb and sunburst on the left, the focused folder's children on the right.
struct StorageMapTab: View {
    let model: StorageModel
    let scan: StorageScan

    private var hovered: SunburstSegment? {
        model.hovered
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                StorageBreadcrumb(model: model)
                StorageSunburst(model: model, hovered: Binding(get: { model.hovered }, set: { model.hovered = $0 }))
                    .frame(minWidth: StorageTokens.Sunburst.minimumSize, minHeight: StorageTokens.Sunburst.minimumHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                hoverLine
            }
            .frame(minWidth: StorageTokens.Sunburst.minimumSize, idealWidth: StorageTokens.Sunburst.idealSize)
            .frame(maxHeight: .infinity, alignment: .top)
            .cardStyle()
            VStack(spacing: 0) {
                if let focus = model.focus {
                    StorageChildrenList(model: model, folder: focus, hoveredPath: hovered?.node?.path)
                }
                if !scan.unreadable.isEmpty {
                    Divider()
                    // A bar under the list, like a table's footer; the list keeps its own background.
                    NotReadableFooter(model: model, paths: scan.unreadable)
                        .background(Tokens.Surfaces.card)
                }
            }
            .frame(minWidth: StorageTokens.Layout.childrenListMinWidth, maxHeight: .infinity)
            .clipShape(Tokens.Shapes.card)
        }
    }

    /// The hovered slice's path and size, or a hint.
    private var hoverLine: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let hovered {
                Text(hoverPath(hovered))
                    .font(Tokens.Typography.codeSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Tokens.Spacing.xs)
                Text(Formatters.bytes(hovered.size))
                    .monospacedDigit()
            } else {
                Text("Click a folder to zoom in, the center to zoom out.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .font(Tokens.Typography.secondary)
        // One height for the hint and the path, whose monospaced font has other metrics, so the
        // sunburst above doesn't resize under the pointer.
        .frame(
            maxWidth: .infinity,
            minHeight: StorageTokens.Sunburst.hoverLineHeight,
            maxHeight: StorageTokens.Sunburst.hoverLineHeight,
            alignment: .leading
        )
    }

    private func hoverPath(_ segment: SunburstSegment) -> String {
        switch segment.content {
        case let .node(node):
            let path = Formatters.displayPath(node.path, home: scan.home)
            return node.kind == .smallFiles ? path + " · " + node.name : path
        case let .merged(parent, count, _):
            return Formatters.displayPath(parent, home: scan.home) + " · " + StorageText.smallerItems(count)
        }
    }
}

/// Where the map is: the scan root down to the focused folder. Each step zooms back to it.
struct StorageBreadcrumb: View {
    let model: StorageModel

    var body: some View {
        let trail = model.breadcrumb
        let shown = trail.count > StorageTokens.Layout.breadcrumbMaxItems
            ? [trail[0]] + trail.suffix(StorageTokens.Layout.breadcrumbMaxItems - 1)
            : trail
        HStack(spacing: Tokens.Spacing.xxs) {
            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(trail.count < 2)
            .help(Text("Back to the enclosing folder", bundle: .strings))
            .accessibilityLabel(Text("Back", bundle: .strings))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: shown.count < trail.count && index == 1 ? "ellipsis" : "chevron.forward")
                        .font(Tokens.Typography.separatorGlyph)
                        .foregroundStyle(.tertiary)
                }
                Button(StorageText.name(of: node)) { model.zoom(to: node) }
                    .buttonStyle(.plain)
                    .fontWeight(index == shown.count - 1 ? .semibold : .regular)
                    .foregroundStyle(index == shown.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(Tokens.Typography.body)
    }
}

/// The focused folder's children, largest first, with a share bar and the item actions.
struct StorageChildrenList: View {
    let model: StorageModel
    let folder: StorageNode
    let hoveredPath: String?

    @Environment(\.colorSchemeContrast) private var contrast
    /// The row under the pointer shows its Show in Finder and Move to Trash buttons.
    @State private var pointerRow: String?
    /// Narrow (beside the map in a minimum-size window), the rows drop the share bar and keep no
    /// room for the buttons until hovered, so names have room (D-177).
    @State private var width: CGFloat = 0

    private var compact: Bool {
        width > 0 && width < StorageTokens.Layout.childrenListCompactWidth
    }

    var body: some View {
        let branches = model.branchOfChild
        let rows = folder.children
        List(rows, selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) { child in
            let tint = branches[child.id].map { StorageTokens.branchColor($0, contrast) } ?? Tokens.Colors.seriesRemainder(contrast)
            StorageRow(node: child, total: folder.size, home: model.home, tint: tint, compact: compact) {
                if child.isItem, !compact || pointerRow == child.path {
                    StorageRowActions(model: model, node: child)
                        .opacity(pointerRow == child.path ? 1 : 0)
                        .allowsHitTesting(pointerRow == child.path)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    pointerRow = child.path
                } else if pointerRow == child.path {
                    pointerRow = nil
                }
            }
            // A background in the slice's color, not a bolder name: a weight change widens
            // the name and re-truncates it under the pointer.
            .listRowBackground(isHovered(child) ? StorageTokens.hoverRow(tint, contrast) : nil)
            .storageFileDrag(child)
        }
        // No alternating stripes: a folder with a few items would fill the rest of the list with
        // empty striped rows. The hovered row's tint marks it instead.
        .listStyle(.inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contextMenu(forSelectionType: String.self) { ids in
            if let node = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                StorageItemMenu(model: model, node: node, showsShortcuts: true)
            }
        } primaryAction: { ids in
            // Double-click or Return opens a folder in the map.
            if let node = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                model.zoom(to: node)
            }
        }
        .storageKeys(model: model, rows: rows, hovered: rows.first { $0.path == pointerRow && $0.kind != .smallFiles })
    }

    /// The hovered slice is this child or inside it.
    private func isHovered(_ child: StorageNode) -> Bool {
        guard let hoveredPath, child.kind != .smallFiles else {
            return false
        }
        return hoveredPath == child.path || hoveredPath.hasPrefix(child.path + "/")
    }
}

struct StorageRow<Actions: View>: View {
    let node: StorageNode
    let total: UInt64
    let home: String
    var tint: Color = Tokens.Colors.accent
    /// No share bar, in a narrow list (D-177).
    var compact = false
    /// Buttons before the share bar; their space is kept so the row never shifts, except in a
    /// compact list, which shows them only on the hovered row.
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: StorageText.symbol(for: node))
                .foregroundStyle(node.kind == .unreadable ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .frame(width: Tokens.IconSize.row)
            Text(StorageText.name(of: node))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: Tokens.Spacing.xs)
            actions()
            if node.kind == .unreadable {
                Text("Not readable", bundle: .strings)
                    .foregroundStyle(.secondary)
            } else {
                if !compact {
                    ShareBar(fraction: total > 0 ? Double(node.size) / Double(total) : 0, tint: tint, shrinks: true)
                }
                Text(Formatters.bytes(node.size))
                    .monospacedDigit()
                    .frame(width: StorageTokens.Layout.sizeColumn, alignment: .trailing)
            }
        }
        .help(Formatters.displayPath(node.path, home: home))
    }
}

extension StorageRow where Actions == EmptyView {
    init(node: StorageNode, total: UInt64, home: String, tint: Color = Tokens.Colors.accent) {
        self.init(node: node, total: total, home: home, tint: tint) { EmptyView() }
    }
}

/// Show in Finder and Move to Trash as buttons, for the row under the pointer. The context
/// menu has the same two, plus Open in Map.
struct StorageRowActions: View {
    let model: StorageModel
    let node: StorageNode

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Button {
                model.reveal(node.path)
            } label: {
                Image(systemName: Tokens.Symbols.revealInFinder)
            }
            .help(Text("Show in Finder", bundle: .strings))
            .accessibilityLabel(Text("Show in Finder", bundle: .strings))
            Button {
                model.askToTrash(path: node.path, name: node.name, size: node.size)
            } label: {
                Image(systemName: "trash")
            }
            .help(Text("Move to Trash…", bundle: .strings))
            .accessibilityLabel(Text("Move to Trash…", bundle: .strings))
        }
        .buttonStyle(.borderless)
    }
}

/// A thin proportional bar next to a size.
struct ShareBar: View {
    let fraction: Double
    var tint: Color = Tokens.Colors.accent
    /// Gives up width (down to a stub) before the row's name does: the folder list beside the map
    /// in a minimum-size window (D-177).
    var shrinks = false

    var body: some View {
        if shrinks {
            GeometryReader { proxy in
                bar(width: proxy.size.width)
            }
            .frame(minWidth: StorageTokens.Layout.shareBarMinWidth, maxWidth: StorageTokens.Layout.shareBarWidth)
            .frame(height: StorageTokens.Layout.shareBarHeight)
            .accessibilityHidden(true)
        } else {
            bar(width: StorageTokens.Layout.shareBarWidth)
                .frame(width: StorageTokens.Layout.shareBarWidth, height: StorageTokens.Layout.shareBarHeight)
                .accessibilityHidden(true)
        }
    }

    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(tint)
                .frame(width: width * CGFloat(min(1, max(0, fraction))))
        }
    }
}

/// Show in Finder and Move to Trash, for rows and table rows.
struct StorageItemMenu: View {
    let model: StorageModel
    let node: StorageNode
    var note: String?
    /// Adds Quick Look, and shows Move to Trash's ⌘⌫, where the list handles those keys.
    var showsShortcuts = false

    var body: some View {
        if node.isDirectory, !node.children.isEmpty {
            Button(String(localized: "Open in Map", bundle: .strings)) {
                model.tab = .map
                model.zoom(to: node)
            }
        }
        if showsShortcuts, node.isItem {
            Button(String(localized: "Quick Look", bundle: .strings, comment: "Menu item: previews a file, like Finder's Quick Look")) {
                model.quickLookURL = URL(fileURLWithPath: node.path)
            }
        }
        Button(String(localized: "Show in Finder", bundle: .strings)) { model.reveal(node.path) }
        if node.isItem {
            Divider()
            Button(String(localized: "Move to Trash…", bundle: .strings), role: .destructive) {
                model.askToTrash(path: node.path, name: node.name, size: node.size, note: note)
            }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
        }
    }
}

extension View {
    /// A file or folder row drags out as its file URL, so Finder can copy or move it; Mactivity
    /// only hands over the URL. Buckets and unreadable folders don't drag.
    @ViewBuilder
    func storageFileDrag(_ node: StorageNode) -> some View {
        if node.isItem {
            draggable(URL(fileURLWithPath: node.path))
        } else {
            self
        }
    }

    /// The Storage lists' keys: space for Quick Look of the selected row (or the one under the
    /// pointer), ⌘⌫ to ask to move the selected row to the Trash, like Finder.
    func storageKeys(model: StorageModel, rows: [StorageNode], hovered: StorageNode? = nil) -> some View {
        quickLookPreview(Binding(get: { model.quickLookURL }, set: { model.quickLookURL = $0 }))
            .onKeyPress(.space) {
                model.toggleQuickLook(in: rows, hovered: hovered)
                return .handled
            }
            .onKeyPress(keys: [.delete]) { press in
                guard press.modifiers == .command else {
                    return .ignored
                }
                model.trashSelection(in: rows)
                return .handled
            }
    }
}

/// The "Not readable" bucket: folders the scan couldn't open, never left out silently.
struct NotReadableFooter: View {
    let model: StorageModel
    let paths: [String]
    @State private var showsList = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text(String(localized: "\(paths.count) folders not readable", bundle: .strings))
            Spacer()
            Button(String(localized: "Show", bundle: .strings, comment: "Shows a list or a section")) {
                showsList.toggle()
            }
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                NotReadableList(model: model, paths: paths)
            }
        }
        .font(Tokens.Typography.secondary)
        .controlSize(.small)
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.xs)
    }
}

struct NotReadableList: View {
    let model: StorageModel
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Not readable", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
            Text(
                "Their sizes aren't in the map. Usually macOS privacy protection; Full Disk Access lets Mactivity read them.",
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            List(paths, id: \.self) { path in
                Text(Formatters.displayPath(path, home: model.home))
                    .font(Tokens.Typography.code)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .listStyle(.bordered)
            .frame(
                minHeight: StorageTokens.Layout.popoverListHeight.lowerBound,
                maxHeight: StorageTokens.Layout.popoverListHeight.upperBound
            )
            Button(String(localized: "Open Privacy & Security…", bundle: .strings)) { model.openFullDiskAccessSettings() }
        }
        .padding(Tokens.Spacing.m)
        .frame(width: StorageTokens.Layout.popoverWidth)
    }
}
