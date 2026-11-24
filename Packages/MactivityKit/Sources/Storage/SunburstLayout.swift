import Foundation

/// One ring segment of the sunburst: a node (or a merged bucket) and its angular span.
public struct SunburstSegment: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case node(StorageNode)
        /// Siblings too thin to draw on their own, merged into one "Other" slice.
        case merged(parentPath: String, count: Int, size: UInt64)
    }

    public let content: Content
    /// 1 is the ring around the center; the center is the focused folder itself.
    public let ring: Int
    /// Radians, clockwise from 12 o'clock, in 0...2π.
    public let startAngle: Double
    public let endAngle: Double
    /// Index of the top-level (ring 1) ancestor, for its color.
    public let branch: Int

    public var id: String {
        switch content {
        case let .node(node): node.id
        case let .merged(parent, _, _): parent + "/\u{1}other"
        }
    }

    public var size: UInt64 {
        switch content {
        case let .node(node): node.size
        case let .merged(_, _, size): size
        }
    }

    public var node: StorageNode? {
        if case let .node(node) = content {
            return node
        }
        return nil
    }

    public var span: Double {
        endAngle - startAngle
    }

    public func contains(angle: Double) -> Bool {
        angle >= startAngle && angle < endAngle
    }
}

/// The sunburst's geometry, as pure math so it's testable (spec E10).
///
/// Each ring shows the children of the ring inside it. A child's span is its share of its
/// parent's size times the parent's span, so every ring's spans add up to its parent's.
/// Children thinner than `minimumAngle` are merged into one "Other" segment per parent, which
/// keeps a folder with 10,000 tiny files from drawing 10,000 hairlines.
public enum SunburstLayout {
    public static let fullCircle = 2 * Double.pi

    public static func segments(for root: StorageNode, rings: Int = 4, minimumAngle: Double = 0.012) -> [SunburstSegment] {
        guard root.size > 0, rings > 0 else {
            return []
        }
        var result: [SunburstSegment] = []
        layOut(
            root,
            ring: 1,
            start: 0,
            span: fullCircle,
            branch: nil,
            rings: rings,
            minimumAngle: minimumAngle,
            into: &result
        )
        return result
    }

    private static func layOut(
        _ parent: StorageNode,
        ring: Int,
        start: Double,
        span: Double,
        branch: Int?,
        rings: Int,
        minimumAngle: Double,
        into result: inout [SunburstSegment]
    ) {
        guard ring <= rings, parent.size > 0 else {
            return
        }
        let total = Double(parent.size)
        var angle = start
        var mergedCount = 0
        var mergedSize: UInt64 = 0
        for (index, child) in parent.children.enumerated() where child.size > 0 {
            let childSpan = span * Double(child.size) / total
            guard childSpan >= minimumAngle else {
                mergedCount += 1
                mergedSize += child.size
                continue
            }
            let childBranch = branch ?? index
            result.append(SunburstSegment(
                content: .node(child),
                ring: ring,
                startAngle: angle,
                endAngle: angle + childSpan,
                branch: childBranch
            ))
            if child.isDirectory {
                layOut(
                    child,
                    ring: ring + 1,
                    start: angle,
                    span: childSpan,
                    branch: childBranch,
                    rings: rings,
                    minimumAngle: minimumAngle,
                    into: &result
                )
            }
            angle += childSpan
        }
        if mergedCount > 0 {
            // Children are sorted largest first, so the merged tail sits at the end of the span.
            result.append(SunburstSegment(
                content: .merged(parentPath: parent.path, count: mergedCount, size: mergedSize),
                ring: ring,
                startAngle: angle,
                endAngle: start + span,
                branch: branch ?? -1
            ))
        }
    }

    /// Angle of a point relative to the center, clockwise from 12 o'clock, in 0..<2π.
    public static func angle(dx: Double, dy: Double) -> Double {
        let raw = atan2(dx, -dy)
        return raw < 0 ? raw + fullCircle : raw
    }

    /// The segment under a point. `ringWidth` and `centerRadius` are the drawing's geometry.
    public static func hit(
        _ segments: [SunburstSegment],
        dx: Double,
        dy: Double,
        centerRadius: Double,
        ringWidth: Double
    ) -> SunburstSegment? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= centerRadius, ringWidth > 0 else {
            return nil
        }
        let ring = Int((distance - centerRadius) / ringWidth) + 1
        let angle = angle(dx: dx, dy: dy)
        return segments.first { $0.ring == ring && $0.contains(angle: angle) }
    }
}
