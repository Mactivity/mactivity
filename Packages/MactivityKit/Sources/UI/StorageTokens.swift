import Core
import Storage
import SwiftUI

/// Storage map tokens (spec 10.3). Kept beside the view so `Tokens.swift` stays the app-wide set;
/// every value here builds on it.
enum StorageTokens {
    /// Top-level folder colors, in order. System colors so both appearances work. No red,
    /// orange, yellow, or green, which mean status (spec 10.2), and no pink, which reads as red
    /// next to them.
    static let branchColors: [Color] = [Tokens.Colors.accent, .purple, .teal, .brown, .indigo, .mint, .cyan]

    static func branchColor(_ branch: Int, _ contrast: ColorSchemeContrast) -> Color {
        guard branch >= 0 else {
            return Tokens.Colors.seriesRemainder(contrast)
        }
        return branchColors[branch % branchColors.count]
    }

    static func color(for category: StorageCategory, _ contrast: ColorSchemeContrast) -> Color {
        switch category {
        case .apps: Tokens.Colors.accent
        case .documents: .indigo
        case .photosAndVideo: .purple
        case .audio: .mint
        case .archives: .brown
        case .developer: .teal
        case .systemAndLibrary: .gray
        case .other: Tokens.Colors.seriesRemainder(contrast)
        }
    }

    /// Capacity bar.
    static let usedColor = Tokens.Colors.accent
    static func purgeableColor(_ contrast: ColorSchemeContrast) -> Color {
        Tokens.Colors.accent.opacity(contrast == .increased ? 0.6 : 0.4)
    }

    static func freeColor(_ contrast: ColorSchemeContrast) -> Color {
        Color.secondary.opacity(contrast == .increased ? 0.35 : 0.18)
    }

    static let capacityBarHeight: CGFloat = 14
    /// Between the segments of a `SegmentedBar`: the capacity bar and the category bar.
    static let capacitySegmentGap: CGFloat = 1
    static let legendDot: CGFloat = 8

    /// The row whose slice is under the pointer in the sunburst: a wash of the slice's color.
    static func hoverRow(_ tint: Color, _ contrast: ColorSchemeContrast) -> Color {
        tint.opacity(contrast == .increased ? 0.3 : 0.15)
    }

    /// Sunburst geometry, as fractions of the chart's radius.
    enum Sunburst {
        static let rings = 4
        static let centerFraction: CGFloat = 0.3
        /// Thinnest slice drawn on its own, in radians; thinner siblings merge into "Other".
        static let minimumAngle = 0.012
        /// Gap between slices, stroked in the card's color.
        static let separator: CGFloat = 1
        static let outerRingFade = 0.14
        static let fileOpacity = 0.55
        /// Lightens a slice in dark mode and darkens it in light mode, where white washed into
        /// the pale outer rings and disappeared.
        static func hoverOverlay(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
            let increased = contrast == .increased
            return scheme == .light ? Color.black.opacity(increased ? 0.3 : 0.18) : Color.white.opacity(increased ? 0.4 : 0.28)
        }

        /// Under Increase Contrast the hovered slice is outlined too.
        static let hoverStroke: CGFloat = 1.5
        /// The chart's narrowest: in a minimum-size window it sits beside the folder list at this
        /// width (D-177: 300 here and 300 for the list widened that window to 892 pt).
        static let minimumSize: CGFloat = 220
        /// The chart's height can go well under its width: in a short window it draws smaller
        /// rather than making the page taller than the window (D-172).
        static let minimumHeight: CGFloat = 120
        static let idealSize: CGFloat = 420
        /// The focused folder's size in the middle.
        static let centerFigure = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let centerLabelWidth: CGFloat = 1.55
        /// The line under the chart: a hint, or the hovered slice's path. Fixed, so the chart
        /// keeps its size whichever is showing.
        static let hoverLineHeight: CGFloat = 16
    }

    enum Layout {
        static let childrenListMinWidth: CGFloat = 240
        /// Narrower than this, the folder list's rows drop the share bar (D-177).
        static let childrenListCompactWidth: CGFloat = 340
        static let sizeColumn: CGFloat = 76
        static let shareBarWidth: CGFloat = 56
        static let shareBarMinWidth: CGFloat = 20
        static let shareBarHeight: CGFloat = 4
        static let filesColumn: CGFloat = 80
        static let noteColumnMin: CGFloat = 260
        static let explainerSymbol: CGFloat = 28
        static let categoryBarHeight: CGFloat = 22
        static let breadcrumbMaxItems = 5
        static let actionsColumn: CGFloat = 48
        static let popoverWidth: CGFloat = 360
        static let popoverListHeight: ClosedRange<CGFloat> = 120 ... 240
        static let nameColumn = (min: CGFloat(180), ideal: CGFloat(260))
        static let pathColumn = (min: CGFloat(180), ideal: CGFloat(320))
        static let kindColumn = (min: CGFloat(90), ideal: CGFloat(120))
        static let shareColumn = (min: CGFloat(100), ideal: CGFloat(140))
        static let locationColumn = (min: CGFloat(220), ideal: CGFloat(300))
        static let noteColumnIdeal: CGFloat = 360
    }
}

/// Text the storage views share. Sizes go through `Formatters.bytes` (SI, like Finder: D-009).
enum StorageText {
    static let fullDiskAccessExplainer = String(
        localized: """
        Without it, macOS hides Mail, Messages, Safari, and other apps' data, and asks about Desktop, Documents, and Downloads \
        one folder at a time. Mactivity maps what it can read and lists the rest as Not Readable.
        """,
        bundle: .strings
    )

    static let categoriesRule = String(
        localized: """
        Everything inside an app bundle counts as Apps, inside a Library as System & library, and inside node_modules, \
        DerivedData, and other build folders as Developer. The rest goes by file type.
        """,
        bundle: .strings
    )

    static let categoriesStale = String(
        localized: "Items moved to the Trash since the scan aren't reflected here yet. Rescan to update.",
        bundle: .strings
    )

    static let developerLensIntro = String(
        localized: """
        Caches, build products, and downloads your tools can recreate. Mactivity never removes any of it on its own; \
        each row says what rebuilding costs.
        """,
        bundle: .strings
    )

    /// "1 file", "1,234 files" (a plural key; the count is grouped like `formatted()`).
    static func files(_ count: Int) -> String {
        String(localized: "\(count) files", bundle: .strings)
    }

    /// "12 smaller items": siblings too thin for a slice of their own, merged into one.
    static func smallerItems(_ count: Int) -> String {
        String(localized: "\(count) smaller items", bundle: .strings, comment: "Sunburst slice merging many small files and folders")
    }

    static func share(_ part: UInt64, of whole: UInt64) -> String {
        guard whole > 0 else {
            return "–"
        }
        return Formatters.percent(Double(part) / Double(whole) * 100)
    }

    static func duration(_ duration: Duration) -> String {
        let seconds = duration.seconds
        // "4.2s", or "4,2 s" where the decimal is a comma (D-221).
        return seconds < 10 ? Formatters.seconds(seconds) : Formatters.duration(duration)
    }

    /// "Home folder" for the home folder itself, else the display path.
    static func place(_ path: String, home: String) -> String {
        path == home ? String(localized: "Home folder", bundle: .strings) : Formatters.displayPath(path, home: home)
    }

    /// A note with `code` spans rendered as code.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// The name Finder shows: "Téléchargements" for ~/Downloads on a French Mac (D-221). Only
    /// for folders right in the home folder, in /Users and at the disk's top, where macOS
    /// translates names; everything else is its name on disk.
    static func name(of node: StorageNode, home: String = NSHomeDirectory()) -> String {
        guard node.kind == .directory else {
            return node.name
        }
        let parent = (node.path as NSString).deletingLastPathComponent
        guard parent == home || parent == "/" || parent == "/Users" || node.path == home else {
            return node.name
        }
        return FileManager.default.displayName(atPath: node.path)
    }

    static func symbol(for node: StorageNode) -> String {
        switch node.kind {
        case .directory: node.name.lowercased().hasSuffix(".app") ? "app.dashed" : "folder.fill"
        case .file: node.category.flatMap { $0 == .other ? nil : $0.symbol } ?? "doc"
        case .smallFiles: "doc.on.doc"
        case .unreadable: "lock.fill"
        }
    }
}
