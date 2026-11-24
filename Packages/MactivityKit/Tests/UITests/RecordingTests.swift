import Core
import Export
import Foundation
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Record a moment (D-151)")
struct RecordingTests {
    @Test("Rows: the Mac first, then busy apps, every metric a column")
    func rows() async {
        let snapshot = await SimulatedSnapshotSource().next()
        let dates = ISO8601DateFormatter()
        let rows = RecordingCSV.rows(snapshot, dates: dates)
        let columns = RecordingCSV.header.split(separator: ",", omittingEmptySubsequences: false).count
        #expect(columns == 3 + Metric.allCases.count)
        #expect(rows.first?.contains(",All apps,") == true)
        #expect(rows.count > 1)
        #expect(rows.count <= 1 + snapshot.apps.count)
        #expect(RecordingCSV.header.contains("On battery (1 or 0)"))
    }

    @Test("Start writes the header; each snapshot adds rows; finish closes the file")
    func writes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactivity-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("test.csv")
        let model = RecordingModel()
        var finished: String?
        model.onFinished = { finished = $0 }
        model.start(to: url, metrics: nil)
        #expect(model.isRecording)
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 3 {
            await model.record(source.next())
        }
        #expect(model.snapshotCount == 3)
        let rowsBefore = await RecordingCSV.rows(source.next(), dates: ISO8601DateFormatter()).count
        #expect(rowsBefore > 0)
        model.stopForTesting()
        #expect(!model.isRecording)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.first.map(String.init) == RecordingCSV.header)
        #expect(lines.count > 3)
        #expect(lines.filter { $0.contains(",All apps,") }.count == 3)
        #expect(finished == nil)
        // Not recording: nothing is written.
        await model.record(source.next())
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test("The suggested name has the date and a time without colons")
    func name() {
        let name = RecordingCSV.suggestedName(at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name.hasPrefix("Mactivity Recording 2027-01-15 at "))
        #expect(name.hasSuffix(".csv"))
        #expect(!name.contains(":"))
    }
}
