import Core
import Storage
import SwiftUI

/// The sunburst, drawn with `Canvas` (not Swift Charts: it's rings of arcs, and it redraws on
/// every hover). The center is the focused folder; each ring is the children of the ring inside
/// it. Hover shows a slice's path and size, clicking a folder zooms in, clicking the center
/// zooms out.
struct StorageSunburst: View {
    let model: StorageModel
    @Binding var hovered: SunburstSegment?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let geometry = Geometry(size: proxy.size)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                centerLabel
                    .frame(
                        width: geometry.centerRadius * StorageTokens.Sunburst.centerLabelWidth,
                        height: geometry.centerRadius * StorageTokens.Sunburst.centerLabelWidth
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    let hit = geometry.hit(model.segments, at: location)
                    if hit?.id != hovered?.id {
                        hovered = hit
                    }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                tap(at: location, geometry: geometry)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: Geometry) {
        context.drawLayer { layer in
            layer.fill(Circle().path(in: geometry.centerRect), with: .style(Tokens.Surfaces.inset))
            for segment in model.segments {
                let path = geometry.path(for: segment)
                layer.fill(path, with: .color(color(for: segment)))
                if segment.id == hovered?.id {
                    layer.fill(path, with: .color(StorageTokens.Sunburst.hoverOverlay(colorScheme, contrast)))
                }
            }
            // Separators in the card's own color, so they read as gaps in both appearances.
            for segment in model.segments {
                layer.stroke(
                    geometry.path(for: segment),
                    with: .style(Tokens.Surfaces.card),
                    lineWidth: StorageTokens.Sunburst.separator
                )
            }
            // After the separators, so they don't cut the outline.
            if contrast == .increased, let hovered {
                layer.stroke(geometry.path(for: hovered), with: .style(.primary), lineWidth: StorageTokens.Sunburst.hoverStroke)
            }
        }
    }

    private func color(for segment: SunburstSegment) -> Color {
        guard let node = segment.node, node.kind != .smallFiles else {
            return Tokens.Colors.seriesRemainder(contrast)
        }
        let base = StorageTokens.branchColor(segment.branch, contrast)
        let fade = 1 - StorageTokens.Sunburst.outerRingFade * Double(segment.ring - 1)
        return node.kind == .file ? base.opacity(fade * StorageTokens.Sunburst.fileOpacity) : base.opacity(fade)
    }

    // MARK: Center

    /// The biggest version that fits the center: a small chart (a short window, D-172) drops the
    /// detail line, then the name, rather than spilling over the rings.
    private var centerLabel: some View {
        ViewThatFits(in: .vertical) {
            centerContent(title: true, detail: true)
            centerContent(title: true, detail: false)
            // Nothing rather than "3…".
            Color.clear
        }
    }

    private func centerContent(title showsTitle: Bool, detail: Bool) -> some View {
        VStack(spacing: Tokens.Spacing.lineGap) {
            if let hovered {
                if showsTitle {
                    Text(title(for: hovered))
                        .font(Tokens.Typography.cardTitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                figure(hovered.size)
                if detail, let focus = model.focus {
                    Text(String(
                        localized: "storage.shareOfFolder",
                        defaultValue: "\(StorageText.share(hovered.size, of: focus.size)) of \(focus.name)",
                        bundle: .strings,
                        comment: "Sunburst center: the hovered slice's share of the focused folder, e.g. 12% of Library"
                    ))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } else if let focus = model.focus {
                if showsTitle {
                    Text(focus.name)
                        .font(Tokens.Typography.cardTitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                figure(focus.size)
                if detail {
                    Text(StorageText.files(focus.fileCount))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    /// The size in the center: the large figure, or a smaller font when the chart is small.
    private func figure(_ bytes: UInt64) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(Formatters.bytes(bytes))
                .font(StorageTokens.Sunburst.centerFigure)
            Text(Formatters.bytes(bytes))
                .font(Tokens.Typography.secondary.weight(.semibold))
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func title(for segment: SunburstSegment) -> String {
        switch segment.content {
        case let .node(node): StorageText.name(of: node)
        case let .merged(_, count, _): StorageText.smallerItems(count)
        }
    }

    // MARK: Input

    private func tap(at location: CGPoint, geometry: Geometry) {
        if geometry.isInCenter(location) {
            model.zoomOut()
            hovered = nil
            return
        }
        guard let segment = geometry.hit(model.segments, at: location) else {
            return
        }
        if let node = segment.node, node.isDirectory {
            model.zoom(to: node)
            hovered = nil
        }
    }

    private var accessibilityText: String {
        guard let focus = model.focus else {
            return String(localized: "Storage map", bundle: .strings)
        }
        let top = focus.children.prefix(3).map { "\($0.name), \(Formatters.bytes($0.size))" }.joined(separator: "; ")
        return String(
            localized: "Storage map of \(focus.name), \(Formatters.bytes(focus.size)). Largest: \(top)",
            bundle: .strings,
            comment: "VoiceOver: the folder, its size, then its three largest items as name, size; name, size"
        )
    }

    /// Ring geometry for one drawing size.
    struct Geometry {
        let center: CGPoint
        let centerRadius: CGFloat
        let ringWidth: CGFloat

        init(size: CGSize) {
            let radius = min(size.width, size.height) / 2
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            centerRadius = radius * StorageTokens.Sunburst.centerFraction
            ringWidth = (radius - centerRadius) / CGFloat(StorageTokens.Sunburst.rings)
        }

        var centerRect: CGRect {
            CGRect(x: center.x - centerRadius, y: center.y - centerRadius, width: centerRadius * 2, height: centerRadius * 2)
        }

        func isInCenter(_ point: CGPoint) -> Bool {
            hypot(point.x - center.x, point.y - center.y) < centerRadius
        }

        func hit(_ segments: [SunburstSegment], at point: CGPoint) -> SunburstSegment? {
            SunburstLayout.hit(
                segments,
                dx: Double(point.x - center.x),
                dy: Double(point.y - center.y),
                centerRadius: Double(centerRadius),
                ringWidth: Double(ringWidth)
            )
        }

        /// An annular sector. Layout angles run clockwise from 12 o'clock; SwiftUI's run from
        /// 3 o'clock, so they're turned back a quarter.
        func path(for segment: SunburstSegment) -> Path {
            let inner = centerRadius + ringWidth * CGFloat(segment.ring - 1)
            let outer = inner + ringWidth
            let start = Angle.radians(segment.startAngle - .pi / 2)
            let end = Angle.radians(segment.endAngle - .pi / 2)
            var path = Path()
            path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
            return path
        }
    }
}
