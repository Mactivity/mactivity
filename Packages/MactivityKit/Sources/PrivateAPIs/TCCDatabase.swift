import Core
import Foundation
import os
import SQLite3

/// The permissions apps have, from the databases macOS keeps them in (1.9, D-261).
///
/// - Symbol: not a function but two SQLite files, the per-user
///   `~/Library/Application Support/com.apple.TCC/TCC.db` (camera, microphone, automation, files
///   and folders) and the system's `/Library/Application Support/com.apple.TCC/TCC.db` (screen
///   recording, Full Disk Access, Accessibility, input monitoring). The `access` table's columns
///   (`service`, `client`, `client_type`, `auth_value`, `last_modified`,
///   `indirect_object_identifier`) aren't documented. Opened read-only; nothing is ever written.
/// - Framework: TCC (Transparency, Consent and Control), private.
/// - Needs Full Disk Access: without it, opening fails and `read` says `.noAccess`.
/// - macOS 27 moved the per-user file into `/private/var/containers/Data/ProtectedSystem/<ID>/`,
///   which refuses even Full Disk Access (tested on 27.2, D-263). So there, only the system's
///   file reads, and `read` names the kinds it can't see instead of implying no app has them.
/// - If Apple changes the table: the query fails, `read` returns `.noAccess`, and the Security
///   page falls back to its public path: each kind's pane in System Settings → Privacy & Security.
public enum TCCDatabase {
    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "tcc")

    static func userPath(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    static let systemPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Both databases' permissions, or as much as could be read of them.
    public static func read(home: String = NSHomeDirectory()) -> PermissionsReading {
        reading(user: rows(at: userPath(home: home)), system: rows(at: systemPath))
    }

    /// Pure: what the two files' rows add up to. Nil means that file couldn't be read.
    static func reading(user: [Row]?, system: [Row]?) -> PermissionsReading {
        guard user != nil || system != nil else {
            return .noAccess
        }
        // The same answer in both databases appears once.
        var seen: Set<String> = []
        let found = ((user ?? []) + (system ?? [])).compactMap(permission).filter { seen.insert($0.id).inserted }
        let unreadable: [PermissionKind] = if user == nil {
            PermissionKind.perUser
        } else if system == nil {
            PermissionKind.allCases.filter { !PermissionKind.perUser.contains($0) }
        } else {
            []
        }
        return .read(found, unreadable: unreadable)
    }

    /// One row of the `access` table, as read.
    struct Row: Equatable {
        let service: String
        let client: String
        let clientType: Int
        let authValue: Int
        let lastModified: Int64?
        let target: String?
    }

    /// Pure: a row as a permission, or nil for a service Mactivity doesn't show or an answer
    /// that's neither yes nor no ("ask again", "limited").
    static func permission(_ row: Row) -> AppPermission? {
        guard let kind = PermissionKind.kind(service: row.service) else {
            return nil
        }
        // auth_value: 0 denied, 2 allowed; 1 is "not decided", 3 "limited" (photos).
        guard row.authValue == 0 || row.authValue == 2 else {
            return nil
        }
        return AppPermission(
            kind: kind, client: row.client, clientIsPath: row.clientType == 1, allowed: row.authValue == 2,
            changed: row.lastModified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            target: kind == .automation ? row.target : nil
        )
    }

    /// The `access` table's rows, or nil when the file can't be opened or the table isn't as
    /// expected.
    static func rows(at path: String) -> [Row]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        let sql = "SELECT service, client, client_type, auth_value, last_modified, indirect_object_identifier FROM access"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            log.notice("TCC's access table isn't as expected: \(String(cString: sqlite3_errmsg(database)), privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let service = text(0), let client = text(1) else {
                continue
            }
            rows.append(Row(
                service: service, client: client, clientType: Int(sqlite3_column_int(statement, 2)),
                authValue: Int(sqlite3_column_int(statement, 3)),
                lastModified: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4),
                target: text(5).flatMap { $0 == "UNUSED" || $0.isEmpty ? nil : $0 }
            ))
        }
        return rows
    }
}
