import Core
import Storage
import SwiftUI

/// Categories tab: one stacked bar of the whole scan, then every category with its share.
struct StorageCategoriesTab: View {
    let model: StorageModel
    let scan: StorageScan

    @Environment(\.colorSchemeContrast) private var contrast

    private var total: UInt64 {
        scan.categories.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                CategoryBar(categories: scan.categories, total: total)
                // Wraps to three lines at most: measured at zero width, a fixed-size line was
                // thousands of points tall and pushed the page under the toolbar (D-172).
                Text(scan.categoriesAreStale ? StorageText.categoriesStale : StorageText.categoriesRule)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .help(scan.categoriesAreStale ? StorageText.categoriesStale : StorageText.categoriesRule)
                    .lineLimit(3)
            }
            .cardStyle()
            Table(scan.categories) {
                TableColumn(Text("Category", bundle: .strings)) { total in
                    HStack(spacing: Tokens.Spacing.xs) {
                        Circle()
                            .fill(StorageTokens.color(for: total.category, contrast))
                            .frame(width: StorageTokens.legendDot, height: StorageTokens.legendDot)
                        Image(systemName: total.category.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: Tokens.IconSize.row)
                        Text(total.category.title)
                    }
                }
                .width(min: StorageTokens.Layout.nameColumn.min, ideal: StorageTokens.Layout.nameColumn.ideal)
                TableColumn(Text("Files", bundle: .strings)) { total in
                    Text(total.fileCount.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(StorageTokens.Layout.filesColumn)
                .alignment(.numeric)
                TableColumn(Text(String(
                    localized: "column.share", defaultValue: "Share", bundle: .strings,
                    comment: "Column: percentage of the scanned space"
                ))) { category in
                    HStack(spacing: Tokens.Spacing.xs) {
                        ShareBar(
                            fraction: total > 0 ? Double(category.bytes) / Double(total) : 0,
                            tint: StorageTokens.color(for: category.category, contrast)
                        )
                        Text(StorageText.share(category.bytes, of: total))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: StorageTokens.Layout.shareColumn.min, ideal: StorageTokens.Layout.shareColumn.ideal)
                TableColumn(Text("Size", bundle: .strings)) { total in
                    Text(Formatters.bytes(total.bytes))
                        .monospacedDigit()
                }
                .width(StorageTokens.Layout.sizeColumn)
                .alignment(.numeric)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(Tokens.Shapes.card)
        }
    }
}

/// The categories as one horizontal bar with a legend.
struct CategoryBar: View {
    let categories: [CategoryTotal]
    let total: UInt64

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SegmentedBar(segments: categories.filter { $0.bytes > 0 }.map { category in
                SegmentedBar.Segment(
                    id: category.category.rawValue,
                    fraction: Double(category.bytes) / Double(max(total, 1)),
                    color: StorageTokens.color(for: category.category, contrast),
                    help: Text(
                        "\(category.category.title): \(Formatters.bytes(category.bytes))",
                        bundle: .strings,
                        comment: "Help tag: a file category and its size"
                    )
                )
            })
            .frame(height: StorageTokens.Layout.categoryBarHeight)
            // Every category, wrapping when the window is narrow: a row capped at six left
            // Documents and Apps out (D-189).
            FlowLayout {
                ForEach(categories.filter { $0.bytes > 0 }) { category in
                    HStack(spacing: Tokens.Spacing.xxs) {
                        Circle()
                            .fill(StorageTokens.color(for: category.category, contrast))
                            .frame(width: StorageTokens.legendDot, height: StorageTokens.legendDot)
                        Text(category.category.title)
                            .foregroundStyle(.secondary)
                        Text(Formatters.bytes(category.bytes))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                }
            }
            .font(Tokens.Typography.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Developer lens: known rebuildable locations, their sizes, and what getting them back costs.
struct DeveloperLensTab: View {
    let model: StorageModel

    private var total: UInt64 {
        model.developerItems.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(model.isLoadingLens ? String(localized: "Measuring developer folders…", bundle: .strings) : headline)
                        .font(Tokens.Typography.cardTitle)
                        .monospacedDigit()
                    Text(StorageText.developerLensIntro)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                if model.isLoadingLens {
                    ProgressView().controlSize(.small)
                }
            }
            .cardStyle()
            if !model.isLoadingLens, model.developerItems.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No developer data found", bundle: .strings), systemImage: "hammer")
                } description: {
                    Text("Xcode, simulators, node_modules, and package caches show up here when they exist.", bundle: .strings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
    }

    private var headline: String {
        String(
            localized: "\(Formatters.bytes(total)) of developer data in \(model.developerItems.count) places",
            bundle: .strings,
            comment: "Developer lens headline: total size, then how many locations"
        )
    }

    private var table: some View {
        Table(model.developerItems) {
            TableColumn(Text("Location", bundle: .strings)) { item in
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(Tokens.Colors.accent)
                        .frame(width: Tokens.IconSize.row)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                        Text(item.title)
                            .font(Tokens.Typography.rowTitle)
                            .lineLimit(1)
                        Text(Formatters.displayPath(item.path, home: model.home))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(item.path)
                .contextMenu { menu(for: item) }
            }
            .width(min: StorageTokens.Layout.locationColumn.min, ideal: StorageTokens.Layout.locationColumn.ideal)
            TableColumn(Text("Size", bundle: .strings)) { item in
                Text(Formatters.bytes(item.size))
                    .monospacedDigit()
            }
            .width(StorageTokens.Layout.sizeColumn)
            .alignment(.numeric)
            TableColumn(Text("Rebuilding", bundle: .strings, comment: "Column: what it costs to get the data back")) { item in
                Text(StorageText.markdown(item.note))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(item.note)
            }
            .width(min: StorageTokens.Layout.noteColumnMin, ideal: StorageTokens.Layout.noteColumnIdeal)
            TableColumn(Text(verbatim: "")) { item in
                HStack(spacing: Tokens.Spacing.xxs) {
                    Button {
                        model.reveal(item.path)
                    } label: {
                        Image(systemName: Tokens.Symbols.revealInFinder)
                    }
                    .help(Text("Show in Finder", bundle: .strings))
                    .accessibilityLabel(Text("Show in Finder", bundle: .strings))
                    Button {
                        model.askToTrash(path: item.path, name: (item.path as NSString).lastPathComponent, size: item.size, note: item.note)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(Text("Move to Trash…", bundle: .strings))
                    .accessibilityLabel(Text("Move to Trash…", bundle: .strings))
                }
                .buttonStyle(.borderless)
            }
            .width(StorageTokens.Layout.actionsColumn)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .clipShape(Tokens.Shapes.card)
    }

    @ViewBuilder private func menu(for item: DeveloperItem) -> some View {
        Button(String(localized: "Show in Finder", bundle: .strings)) { model.reveal(item.path) }
        Divider()
        Button(String(localized: "Move to Trash…", bundle: .strings), role: .destructive) {
            model.askToTrash(path: item.path, name: (item.path as NSString).lastPathComponent, size: item.size, note: item.note)
        }
    }
}

/// Largest files tab: the top 100 files in the scan.
struct LargestFilesTab: View {
    let model: StorageModel
    let scan: StorageScan

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let rows = scan.largestFiles
        Table(rows, selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
            TableColumn(Text("Name", bundle: .strings)) { node in
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: StorageText.symbol(for: node))
                        .foregroundStyle(node.category.map { StorageTokens.color(for: $0, contrast) } ?? .secondary)
                        .frame(width: Tokens.IconSize.row)
                    Text(StorageText.name(of: node))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .storageFileDrag(node)
            }
            .width(min: StorageTokens.Layout.nameColumn.min, ideal: StorageTokens.Layout.nameColumn.ideal)
            TableColumn(Text("Folder", bundle: .strings)) { node in
                Text(Formatters.displayPath((node.path as NSString).deletingLastPathComponent, home: scan.home))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.path)
            }
            .width(min: StorageTokens.Layout.pathColumn.min, ideal: StorageTokens.Layout.pathColumn.ideal)
            TableColumn(Text("Kind", bundle: .strings)) { node in
                Text(node.category?.title ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: StorageTokens.Layout.kindColumn.min, ideal: StorageTokens.Layout.kindColumn.ideal)
            TableColumn(Text("Size", bundle: .strings)) { node in
                Text(Formatters.bytes(node.size))
                    .monospacedDigit()
            }
            .width(StorageTokens.Layout.sizeColumn)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let node = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                StorageItemMenu(model: model, node: node, showsShortcuts: true)
            }
        }
        .storageKeys(model: model, rows: rows)
        .clipShape(Tokens.Shapes.card)
    }
}
