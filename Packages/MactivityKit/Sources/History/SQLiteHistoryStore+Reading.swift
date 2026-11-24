import Core
import Foundation
import GRDB

extension SQLiteHistoryStore {
    /// The app's history for reading only (D-193): the `mactivity` command and its MCP server
    /// read it while the app writes. No migration, no retention, nothing written; a database from
    /// an older Mactivity simply lacks the newer tables, and reading those throws.
    ///
    /// A read-only connection can't open a WAL database whose `-wal` and `-shm` files are gone (a
    /// copy or a restore of the history file alone): SQLITE_CANTOPEN. Then it opens the file as
    /// immutable, still read-only: with no `-shm`, no connection has it open to change it (D-202).
    public static func openReadOnly(url: URL) throws -> SQLiteHistoryStore {
        var configuration = Configuration()
        configuration.label = "Mactivity.history.reader"
        configuration.readonly = true
        do {
            return try SQLiteHistoryStore(reading: DatabaseQueue(path: url.path, configuration: configuration), url: url)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.path + "-shm"),
                  var immutable = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw error
            }
            immutable.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            return try SQLiteHistoryStore(reading: DatabaseQueue(path: immutable.string ?? "", configuration: configuration), url: url)
        }
    }

    /// Renames the database and its WAL and shared-memory files with a `-damaged-<date>` suffix.
    static func moveAside(_ url: URL, date: Date = Date()) throws {
        let stamp = date
            .formatted(Date.ISO8601FormatStyle(timeZone: .autoupdatingCurrent).year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else {
                continue
            }
            let target = directory.appendingPathComponent("\(base)-damaged-\(stamp).\(url.pathExtension)\(suffix)")
            try FileManager.default.moveItem(at: source, to: target)
        }
    }
}
