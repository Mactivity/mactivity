import Core
import Foundation

/// What macOS flagged (D-212): resource reports, memory kills, panics and shutdown stalls from
/// /Library/Logs/DiagnosticReports and its Retired folder, which everyone can read. Local files
/// only; a resource report's first 8 KB, a JetsamEvent whole (it's a few hundred KB at most).
public struct LiveMacReports: MacReportSource {
    let folders: [URL]

    public init(root: URL = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)) {
        folders = [root, root.appendingPathComponent("Retired", isDirectory: true)]
    }

    public func macReports(since date: Date) async -> [MacReport] {
        var found: [MacReport] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= date else {
                    continue
                }
                found += Self.read(file).filter { $0.at >= date }
            }
        }
        return found.sorted { $0.at > $1.at }
    }

    static func read(_ file: URL) -> [MacReport] {
        let path = file.path
        switch file.pathExtension {
        case "diag":
            return head(file, bytes: 8192).flatMap { MacReportParser.resource($0, path: path) }.map { [$0] } ?? []
        case "shutdownStall":
            return shutdownStall(fileName: file.lastPathComponent, path: path).map { [$0] } ?? []
        case "ips", "panic":
            guard let text = head(file, bytes: 2_000_000) else {
                return []
            }
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = lines.first, let header = json(String(first)) else {
                return []
            }
            let body = lines.count > 1 ? String(lines[1]) : ""
            if header["bug_type"] as? String == "298" {
                // Most JetsamEvents close only processes over their own limit: skip parsing a few
                // hundred KB of JSON unless a shortage reason is in there at all.
                guard ["vm-pageshortage", "vnode-limit", "fc-thrashing", "vm-compressor"].contains(where: body.contains) else {
                    return []
                }
                return json(body).map { MacReportParser.memoryKills(header: header, body: $0, path: path) } ?? []
            }
            return MacReportParser.panic(header: header, body: body, path: path).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// "shutdown_stall_2026-10-09-160145_M5Pro.shutdownStall", local time.
    static func shutdownStall(fileName: String, path: String) -> MacReport? {
        let parts = fileName.split(separator: "_")
        guard parts.count >= 3 else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let date = formatter.date(from: String(parts[2])) else {
            return nil
        }
        return MacReport(id: path, at: date, kind: .shutdownStall, process: nil, ownerBundleID: nil, path: path)
    }

    private static func head(_ file: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else {
            return nil
        }
        // A cut inside a multi-byte character leaves up to 3 stray bytes at the end; drop them
        // rather than lose the whole report.
        return (0 ... 3).lazy.compactMap { String(bytes: data.dropLast($0), encoding: .utf8) }.first
    }

    private static func json(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
