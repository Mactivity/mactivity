import Foundation
import Storage
import Testing
@testable import UI

/// Records what it was asked to move; moves nothing.
private final class RecordingTrasher: StorageTrashing, @unchecked Sendable {
    private(set) var moved: [String] = []

    func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
        moved.append(confirmation.path)
        return nil
    }
}

@MainActor
@Suite("Uninstall model (D-104)")
struct UninstallModelTests {
    private func makeApp() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("un-\(UUID().uuidString)/Tool.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.example.tool-\(UUID().uuidString)", "CFBundleName": "Tool"]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test("Nothing moves until perform, and then only what's ticked")
    func onlyTicked() async throws {
        let app = try makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let model = UninstallModel()
        await model.prepare(app)
        let plan = try #require(model.plan)
        #expect(model.selected.contains(plan.appPath))
        let trasher = RecordingTrasher()
        #expect(trasher.moved.isEmpty)

        model.selected.remove(plan.appPath)
        var toast = ""
        await model.perform(using: trasher) { toast = $0 }
        #expect(trasher.moved.isEmpty)
        #expect(model.plan == nil)
        #expect(!toast.isEmpty)
    }

    // The three below hand the model a plan and a trasher that only records, so they prove what
    // `perform` passes on and what its last check refuses. No path in them has to exist.

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let bundleID = "com.example.tool-\(UUID().uuidString)"

    private func plan(_ items: [UninstallItem], appPath: String) -> UninstallPlan {
        UninstallPlan(appName: "Tool", bundleID: bundleID, appPath: appPath, items: items)
    }

    @Test("The ticked app and leftovers reach the Trash in order; a name-only match stays behind")
    func movesTickedAppAndLeftovers() async {
        let appPath = "/Applications/Tool-\(UUID().uuidString).app"
        let cache = "\(home)/Library/Caches/\(bundleID)"
        let byName = "\(home)/Library/Application Support/Tool-\(UUID().uuidString)"
        let model = UninstallModel(loaded: plan([
            UninstallItem(path: appPath, kind: .app, size: 10, matchedByName: false),
            UninstallItem(path: cache, kind: .caches, size: 5, matchedByName: false),
            UninstallItem(path: byName, kind: .applicationSupport, size: 1, matchedByName: true),
        ], appPath: appPath))
        #expect(model.selected == [appPath, cache])
        #expect(model.selectedSize == 15)

        let trasher = RecordingTrasher()
        var moved = false
        model.onMoved = { moved = true }
        var toast = ""
        await model.perform(using: trasher) { toast = $0 }
        #expect(trasher.moved == [appPath, cache])
        #expect(moved)
        #expect(model.plan == nil)
        #expect(toast.contains("Tool"))
    }

    @Test("A ticked leftover outside the Library folders the plan looks in is refused and named (D-140)")
    func refusesLeftoverOutsideScope() async {
        let appPath = "/Applications/Tool-\(UUID().uuidString).app"
        let document = "keep-\(UUID().uuidString)"
        let outside = [
            "\(home)/Library/Mail",
            "\(home)/Documents/\(document)",
            "\(home)/Library/Caches/\(bundleID)/../../Mail",
            "\(home)/Library/Caches",
            "\(home)/Library/Caches/\(bundleID)/inside",
        ]
        let model = UninstallModel(loaded: plan(
            outside.map { UninstallItem(path: $0, kind: .caches, size: 1, matchedByName: false) },
            appPath: appPath
        ))
        #expect(model.selected == Set(outside))

        let trasher = RecordingTrasher()
        var toast = ""
        await model.perform(using: trasher) { toast = $0 }
        #expect(trasher.moved.isEmpty)
        #expect(toast.contains("Mail"))
        #expect(toast.contains(document))
    }

    @Test("An item marked as the app is moved only if it is the app that was picked")
    func refusesAnotherApp() async {
        let appPath = "/Applications/Tool-\(UUID().uuidString).app"
        let other = "/Applications/Other-\(UUID().uuidString).app"
        // Marked as an app but sitting where a leftover may be: still not the app picked.
        let disguised = "\(home)/Library/Caches/\(bundleID)"
        let model = UninstallModel(loaded: plan([
            UninstallItem(path: appPath, kind: .app, size: 10, matchedByName: false),
            UninstallItem(path: other, kind: .app, size: 10, matchedByName: false),
            UninstallItem(path: disguised, kind: .app, size: 10, matchedByName: false),
        ], appPath: appPath))

        let trasher = RecordingTrasher()
        var toast = ""
        await model.perform(using: trasher) { toast = $0 }
        #expect(trasher.moved == [appPath])
        #expect(toast.contains("Other-"))
    }

    @Test("A macOS app gets an explanation, not a plan")
    func systemApp() async {
        let model = UninstallModel()
        await model.prepare(URL(fileURLWithPath: "/System/Applications/Chess.app"))
        #expect(model.plan == nil)
        #expect(model.problem != nil)
    }
}
