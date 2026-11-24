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
}
