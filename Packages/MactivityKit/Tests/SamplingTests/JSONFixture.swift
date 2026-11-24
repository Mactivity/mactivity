import Foundation

/// Loads a fixture as untyped Foundation objects, the shape IOKit and IOPS dictionaries arrive in
/// (`NSNumber`, `NSString`, `NSArray`, `NSDictionary`).
enum JSONFixture {
    struct NotAnObject: Error {}

    static func object(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAnObject()
        }
        return object
    }
}

/// Average wall time of `body` over `calls` runs, after one warm-up call, in milliseconds.
func averageMilliseconds(calls: Int = 20, _ body: () async throws -> Void) async rethrows -> Double {
    try await body()
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0 ..< calls {
        try await body()
    }
    let elapsed = (clock.now - start).components
    return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / Double(calls)
}

/// Writes one timing line to stderr, where `swift test` shows it. Tests can't use `print`.
func reportTiming(_ label: String, _ milliseconds: Double) {
    let line = "[timing] \(label): \(String(format: "%.3f", milliseconds)) ms/call\n"
    FileHandle.standardError.write(Data(line.utf8))
}
