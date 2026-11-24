import Core
import Foundation

/// Crash and hang reports (D-098): the files macOS keeps in ~/Library/Logs/DiagnosticReports and
/// its Retired folder, and the hangs spindump writes to /Library/Logs/DiagnosticReports (D-212).
/// Local files only; only each report's first line is read.
public struct LiveCrashReports: CrashReportSource {
    let folders: [URL]
    /// Read for hangs only: the system folder's crashes are system processes'.
    let hangFolders: [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        system: URL = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
    ) {
        let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        folders = [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
        hangFolders = [system, system.appendingPathComponent("Retired", isDirectory: true)]
    }

    public func reports(since date: Date) async -> [CrashReport] {
        var found: [CrashReport] = []
        for folder in folders + hangFolders {
            let hangsOnly = hangFolders.contains(folder)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= date, let report = Self.read(file), report.at >= date,
                      !hangsOnly || report.kind == .hang else {
                    continue
                }
                found.append(report)
            }
        }
        // A hang written to both folders counts once.
        var seen = Set<String>()
        return found.sorted { $0.at > $1.at }
            .filter { seen.insert("\($0.kind)\u{1F}\($0.appName)\u{1F}\($0.at.timeIntervalSince1970)").inserted }
    }

    /// The first line of a report, at most 4 KB.
    static func read(_ file: URL) -> CrashReport? {
        guard ["ips", "hang", "spin"].contains(file.pathExtension),
              let handle = try? FileHandle(forReadingFrom: file)
        else {
            return nil
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let firstLine = String(bytes: head.prefix { $0 != 0x0A }, encoding: .utf8) ?? ""
        return parse(fileName: file.lastPathComponent, firstLine: firstLine, path: file.path)
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter
    }()

    /// Pure. An .ips's first line is a JSON header: `bug_type` 309 is a crash, and a file named
    /// `ExcUserFault_…` is a fault the app survived, left out. .hang and .spin files are hangs,
    /// named after the app ("Safari_2026-09-23-145207_Mac.hang").
    static func parse(fileName: String, firstLine: String, path: String) -> CrashReport? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if ext == "hang" || ext == "spin" {
            let parts = name.split(separator: "_")
            guard let app = parts.first, parts.count >= 2,
                  let date = hangDate(String(parts[1]))
            else {
                return nil
            }
            return CrashReport(id: path, at: date, appName: String(app), bundleID: nil, kind: .hang, path: path)
        }
        guard !fileName.hasPrefix("ExcUserFault_"),
              let data = firstLine.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              header["bug_type"] as? String == "309",
              let app = (header["app_name"] as? String) ?? (header["name"] as? String),
              let stamp = header["timestamp"] as? String,
              let date = timestamp.date(from: stamp)
        else {
            return nil
        }
        return CrashReport(
            id: path, at: date, appName: app, bundleID: header["bundleID"] as? String, kind: .crash, path: path,
            appVersion: header["app_version"] as? String
        )
    }

    /// "2026-09-23-145207", local time.
    private static func hangDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: text)
    }
}
