import Core
import Foundation

/// Loads JSON fixtures from `Tests/Fixtures/`, shared by every test target.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A 4-core Mac with six apps: macOS, Xcode, Safari, Slack, a bare `node`, and Terminal.
    static func snapshot() throws -> Snapshot {
        try load("snapshot-readouts.json")
    }

    static let english = Locale(identifier: "en_US")
    static let now = Date(timeIntervalSince1970: 1_790_330_400)

    /// Two projects: a working Vite app and an idle API with two ports.
    static func projects() -> [Project] {
        let web = DevServer(
            pid: 4312, name: "node", command: "node node_modules/.bin/vite --port 4321", runtime: .node, ports: [4321],
            memoryBytes: 480_247_808, startedAt: now.addingTimeInterval(-7500), cpuTime: .seconds(95), activity: .working,
            stopTarget: .processGroup(4312)
        )
        let api = DevServer(
            pid: 5120, name: "python3", command: "python3 -m uvicorn app:api", runtime: .python, ports: [8080, 8081],
            memoryBytes: 96_468_992, startedAt: now.addingTimeInterval(-10800), cpuTime: .milliseconds(70500),
            activity: .idle(minutes: 125), stopTarget: .process(5120)
        )
        return [
            Project(rootPath: "/Users/demo/Developer/storefront-web", name: "storefront-web", servers: [web]),
            Project(rootPath: "/Users/demo/Developer/api", name: "api", servers: [api]),
        ]
    }

    /// Parses JSON output back into Foundation objects for key-by-key checks.
    static func object(_ json: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let object = value as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }
}
