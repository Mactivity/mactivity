import SwiftUI

/// Moving Overview's tiles by dragging them (D-242).
extension OverviewView {
    /// The order on screen: during a drag, with the dragged tile where the pointer has taken it.
    var arranged: OverviewLayout {
        preview ?? layout
    }

    func drag(_ tile: OverviewTile) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !settling else {
                    return
                }
                if dragging == nil {
                    dragStart = frames[tile] ?? .zero
                    dragging = tile
                }
                dragTranslation = value.translation
                // Over another tile, take its place. Over the open place or a gap, stay put: the
                // tiles moved under the pointer, and changing again would make them bounce.
                // Each move is from the order on screen, so going back over a tile that made room
                // puts it back.
                if let over = frames.first(where: { $0.key != tile && $0.value.contains(value.location) })?.key,
                   arranged.visible.contains(over) {
                    preview = arranged.moving(tile, onto: over)
                }
            }
            .onEnded { _ in
                guard let tile = dragging, !settling else {
                    return
                }
                let final = arranged
                settling = true
                // Glide into the open place, then make it the real order.
                let slot = frames[tile] ?? dragStart
                withAnimation(reduceMotion ? nil : ReorderableStack<OverviewTile, EmptyView>.slide) {
                    dragTranslation = CGSize(width: slot.minX - dragStart.minX, height: slot.minY - dragStart.minY)
                } completion: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        layout = final
                        dragging = nil
                        preview = nil
                        dragTranslation = .zero
                        settling = false
                    }
                }
            }
    }
}
