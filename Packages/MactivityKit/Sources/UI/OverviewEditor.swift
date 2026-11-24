import SwiftUI

/// Edit Overview (D-241): every tile in its place, a switch to show or hide it, and a tile dropped
/// on another takes its place.
/// Move Up and Move Down do the same from the keyboard and VoiceOver.
struct OverviewEditor: View {
    @Binding var layout: OverviewLayout
    let hasBattery: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Edit Overview", bundle: .strings, comment: "Sheet title: reorder or hide Overview's tiles")
                    .font(Tokens.Typography.sheetTitle)
                Text(
                    "Drag tiles into the order you like, and switch off what you don't need. Tiles on Overview drag the same way.",
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            ReorderableStack(items: layout.order, dividerInset: Tokens.Spacing.s, move: { tile, index in
                layout = layout.moving(tile, toIndex: index)
            }, row: { tile in
                row(tile).padding(.horizontal, Tokens.Spacing.s)
            })
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(Tokens.Surfaces.card, in: Tokens.Shapes.card)
            HStack {
                Button(String(localized: "Back to the Defaults", bundle: .strings, comment: "Customize: undoes every choice")) {
                    layout = .standard
                }
                .disabled(layout.isStandard)
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 420)
        .animation(Tokens.Motion.figure, value: layout)
    }

    private func row(_ tile: OverviewTile) -> some View {
        let title = tile.title(hasBattery: hasBattery)
        let shown = Binding(get: { !layout.hidden.contains(tile) }, set: { layout = layout.showing(tile, $0) })
        return HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Image(systemName: tile.symbol)
                .foregroundStyle(tile.metric?.tint ?? .secondary)
                .frame(width: Tokens.IconSize.row)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(shown.wrappedValue ? .primary : .secondary)
            if tile.isWide {
                Text("Full width", bundle: .strings, comment: "Edit Overview: a tile that spans the page")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .contextMenu {
            Button(String(localized: "Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) { move(tile, by: -1) }
                .disabled(layout.order.first == tile)
            Button(String(localized: "Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) { move(tile, by: 1) }
                .disabled(layout.order.last == tile)
            Button(String(localized: "Move to Top", bundle: .strings, comment: "Overview tile menu")) { layout = layout.toTop(tile) }
                .disabled(layout.order.first == tile)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
            move(tile, by: -1)
        }
        .accessibilityAction(named: Text("Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
            move(tile, by: 1)
        }
    }

    private func move(_ tile: OverviewTile, by offset: Int) {
        guard let index = layout.order.firstIndex(of: tile) else {
            return
        }
        let target = index + offset
        guard layout.order.indices.contains(target) else {
            return
        }
        layout = layout.moving(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
    }
}
