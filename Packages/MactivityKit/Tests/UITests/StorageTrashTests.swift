import Foundation
import Storage
import Testing
@testable import UI

/// Move to Trash goes through its confirm step, and survives the dialog's order of events.
@MainActor
@Suite("Storage trash confirmation")
struct StorageTrashTests {
    /// Records what reached the trasher.
    actor RecordingTrasher: StorageTrashing {
        private(set) var paths: [String] = []

        func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
            paths.append(confirmation.path)
            return nil
        }
    }

    @Test("Nothing moves without a yes; a cancel moves nothing")
    func cancelMovesNothing() async {
        let step = StorageTrashConfirmation()
        let trasher = RecordingTrasher()
        step.ask(path: "/tmp/a", name: "a", size: 1) { _ in }
        step.cancel()
        await step.confirm(using: trasher)
        #expect(await trasher.paths.isEmpty)
    }

    @Test("The dialog's order of events still moves the item: accept, the dismissal's cancel, then perform")
    func dialogOrder() async throws {
        let step = StorageTrashConfirmation()
        let trasher = RecordingTrasher()
        var finished = false
        step.ask(path: "/tmp/DerivedData", name: "DerivedData", size: 18_000_000_000) { _ in finished = true }
        let request = try #require(step.accept())
        step.cancel()
        await step.perform(request, using: trasher)
        #expect(await trasher.paths == ["/tmp/DerivedData"])
        #expect(finished)
        #expect(step.accept() == nil)
    }
}
