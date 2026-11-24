import Core
import Foundation
@testable import PrivateAPIs
import SQLite3
import Testing

@Suite("Permissions from TCC (D-261)")
struct TCCDatabaseTests {
    /// A database with `access` as macOS 26 has it (the columns read, and a few more).
    func database(_ sql: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-\(UUID().uuidString).db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return path
    }

    static let schema = """
    CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, auth_value INTEGER NOT NULL,
      auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB, policy_id INTEGER,
      indirect_object_identifier_type INTEGER, indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
      indirect_object_code_identity BLOB, flags INTEGER, last_modified INTEGER NOT NULL DEFAULT 0);
    """

    @Test("Allowed and denied, by kind; undecided answers and unknown services left out")
    func read() throws {
        let path = try database(Self.schema + """
        INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, indirect_object_identifier)
        VALUES ('kTCCServiceCamera', 'us.zoom.xos', 0, 2, 2, 1, 1790000000, 'UNUSED'),
               ('kTCCServiceMicrophone', 'com.example.denied', 0, 0, 2, 1, 1790000000, 'UNUSED'),
               ('kTCCServiceSystemPolicyAllFiles', '/usr/local/bin/tool', 1, 2, 2, 1, 1790000000, 'UNUSED'),
               ('kTCCServiceAppleEvents', 'com.apple.Terminal', 0, 2, 2, 1, 1790000000, 'com.apple.finder'),
               ('kTCCServicePhotos', 'com.example.photos', 0, 3, 2, 1, 1790000000, 'UNUSED'),
               ('kTCCServiceSomethingNew', 'com.example.new', 0, 2, 2, 1, 1790000000, 'UNUSED');
        """)
        let rows = try #require(TCCDatabase.rows(at: path))
        let permissions = rows.compactMap(TCCDatabase.permission)
        #expect(permissions.map(\.kind) == [.camera, .microphone, .fullDiskAccess, .automation])
        #expect(permissions.map(\.allowed) == [true, false, true, true])
        #expect(permissions[2].clientIsPath && permissions[2].client == "/usr/local/bin/tool")
        #expect(permissions[3].target == "com.apple.finder" && permissions[0].target == nil)
        #expect(permissions[0].changed == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test("Fallback: a table that changed, or no file, reads as no access")
    func fallback() throws {
        let changed = try database("CREATE TABLE access (svc TEXT, who TEXT);")
        #expect(TCCDatabase.rows(at: changed) == nil)
        #expect(TCCDatabase.rows(at: "/nonexistent/TCC.db") == nil)
        #expect(TCCDatabase.reading(user: nil, system: nil) == .noAccess)
    }

    static func row(_ service: String, _ client: String) -> TCCDatabase.Row {
        TCCDatabase.Row(service: service, client: client, clientType: 0, authValue: 2, lastModified: nil, target: nil)
    }

    @Test("macOS 27: only the system's file reads, so its kinds show and the rest are named as unreadable")
    func perUserFileRefused() {
        let reading = TCCDatabase.reading(user: nil, system: [Self.row("kTCCServiceScreenCapture", "us.zoom.xos")])
        guard case let .read(found, unreadable) = reading else {
            Issue.record("Expected a partial reading")
            return
        }
        #expect(found.map(\.kind) == [.screenRecording])
        #expect(unreadable == [.camera, .microphone, .automation, .files])
    }

    @Test("macOS 26: both files read, and nothing is left out")
    func bothRead() {
        let reading = TCCDatabase.reading(
            user: [Self.row("kTCCServiceCamera", "us.zoom.xos")], system: [Self.row("kTCCServiceScreenCapture", "us.zoom.xos")]
        )
        guard case let .read(found, unreadable) = reading else {
            Issue.record("Expected a full reading")
            return
        }
        #expect(found.map(\.kind) == [.camera, .screenRecording] && unreadable.isEmpty)
    }

    @Test("Only the per-user file reads: the system's kinds are the unreadable ones")
    func systemFileRefused() {
        guard case let .read(_, unreadable) = TCCDatabase.reading(user: [], system: nil) else {
            Issue.record("Expected a partial reading")
            return
        }
        #expect(unreadable == [.screenRecording, .fullDiskAccess, .accessibility, .inputMonitoring])
    }
}
