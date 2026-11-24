import SwiftUI

/// A vertical list reordered by dragging (D-242): the row lifts and follows the pointer, the
/// others slide out of its way as it passes them, and on release it settles into its place. The
/// system's drag and drop showed a ghost image and moved nothing until the drop.
///
/// Rows can differ in height; each is measured. Drags start after a few points, so a click on a
/// row, or on a control in it, still works.
struct ReorderableStack<Item: Identifiable & Equatable, Row: View>: View {
    let items: [Item]
    var spacing: CGFloat = 0
    /// A hairline between rows, from this inset; none next to the lifted row's open place.
    var dividerInset: CGFloat?
    /// The item and the index it was dropped at, in `items` without it moved yet.
    let move: (Item, Int) -> Void
    @ViewBuilder let row: (Item) -> Row

    @State private var dragging: Item.ID?
    @State private var translation: CGFloat = 0
    @State private var heights: [Item.ID: CGFloat] = [:]
    @State private var settling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let order = preview
        VStack(spacing: spacing) {
            ForEach(Array(order.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .top) {
                        if let inset = dividerInset, index > 0, item.id != dragging, order[index - 1].id != dragging {
                            Divider().padding(.leading, inset)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[item.id] = $0 }
                    // Its place stays open under the lifted copy.
                    .opacity(item.id == dragging ? 0 : 1)
                    .contentShape(.rect)
                    .highPriorityGesture(drag(item))
            }
        }
        .animation(reduceMotion ? nil : Self.slide, value: order.map(\.id))
        .overlay(alignment: .top) {
            if let dragging, let item = items.first(where: { $0.id == dragging }) {
                row(item)
                    .background(Tokens.Surfaces.card, in: .rect(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                    .scaleEffect(settling || reduceMotion ? 1 : 1.02)
                    .offset(y: top(of: dragging, in: items) + translation)
                    .allowsHitTesting(false)
            }
        }
    }

    static var slide: Animation {
        .spring(response: 0.3, dampingFraction: 0.82)
    }

    /// The order on screen: the dragged row at the place the pointer has reached.
    private var preview: [Item] {
        guard let dragging, let index = items.firstIndex(where: { $0.id == dragging }) else {
            return items
        }
        var order = items
        let item = order.remove(at: index)
        order.insert(item, at: target(for: dragging))
        return order
    }

    /// Where the dragged row's middle is, among the others' middles.
    private func target(for id: Item.ID) -> Int {
        let middle = top(of: id, in: items) + translation + height(id) / 2
        var y: CGFloat = 0
        var index = 0
        for item in items where item.id != id {
            if y + height(item.id) / 2 < middle {
                index += 1
            }
            y += height(item.id) + spacing
        }
        return index
    }

    private func top(of id: Item.ID, in order: [Item]) -> CGFloat {
        var y: CGFloat = 0
        for item in order {
            if item.id == id {
                return y
            }
            y += height(item.id) + spacing
        }
        return y
    }

    private func height(_ id: Item.ID) -> CGFloat {
        heights[id] ?? 0
    }

    private func drag(_ item: Item) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !settling else {
                    return
                }
                if dragging == nil {
                    dragging = item.id
                }
                translation = value.translation.height
            }
            .onEnded { _ in
                guard let id = dragging, !settling else {
                    return
                }
                let index = target(for: id)
                let order = preview
                // Glide into the open place, then make it the real order.
                let settle = top(of: id, in: order) - top(of: id, in: items)
                settling = true
                withAnimation(reduceMotion ? nil : Self.slide) {
                    translation = settle
                } completion: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        move(item, index)
                        dragging = nil
                        translation = 0
                        settling = false
                    }
                }
            }
    }
}
