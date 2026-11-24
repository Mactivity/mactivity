import Foundation

/// A plain-text table with space-aligned columns. The last column is never padded, so lines
/// don't end in spaces.
struct TextTable {
    enum Alignment {
        case left, right
    }

    struct Column {
        let title: String
        let alignment: Alignment
    }

    let columns: [Column]
    var rows: [[String]] = []
    var gap = 2

    init(_ columns: [Column]) {
        self.columns = columns
    }

    mutating func add(_ row: [String]) {
        rows.append(row)
    }

    func render(header: Bool = true) -> String {
        let all = (header ? [columns.map(\.title)] : []) + rows
        var widths = Array(repeating: 0, count: columns.count)
        for row in all {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], Self.columns(cell))
            }
        }
        return all.map { row in
            var line = ""
            for index in columns.indices {
                let cell = index < row.count ? row[index] : ""
                let padding = String(repeating: " ", count: max(0, widths[index] - Self.columns(cell)))
                let isLast = index == columns.count - 1
                switch columns[index].alignment {
                case .left: line += isLast ? cell : cell + padding
                case .right: line += padding + cell
                }
                if !isLast {
                    line += String(repeating: " ", count: gap)
                }
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// How many terminal columns `text` takes: two for each wide character, so a table of
    /// Japanese, Chinese or Korean app names ("カレンダー") still lines up (D-221).
    static func columns(_ text: String) -> Int {
        text.reduce(0) { total, character in
            total + (character.unicodeScalars.first.map(isWide) == true ? 2 : 1)
        }
    }

    /// East Asian Wide and Fullwidth: Hangul, CJK, kana, full-width forms, and emoji.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF,
             0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6,
             0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x20000 ... 0x3FFFD:
            true
        default:
            false
        }
    }

    /// Shortens `text` to `limit` characters with a trailing ellipsis.
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(0, limit - 1))) + "…"
    }
}
