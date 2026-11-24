import Core
import Foundation
import Storage
import Testing
@testable import UI

/// What the rows' menus and keys do: Projects' links, Storage's selection, muting an app.
@MainActor
@Suite("Row actions")
struct RowActionsTests {
    private static func server(ports: [UInt16]) -> DevServer {
        DevServer(
            pid: 10, name: "node", command: "node", runtime: .node, ports: ports, memoryBytes: 1,
            startedAt: Date(), cpuTime: .zero, activity: .working, stopTarget: .processGroup(10)
        )
    }

    @Test("A project's menu opens and copies http://localhost:PORT for each port, lowest first")
    func projectLinks() {
        let project = Project(rootPath: "/Users/me/storefront", name: "storefront", servers: [
            Self.server(ports: [5173, 3000]),
            Self.server(ports: [3000]),
        ])
        let links = ProjectLinks(project)
        #expect(links.urls.map(\.absoluteString) == ["http://localhost:3000", "http://localhost:5173"])
        #expect(links.urls.map(ProjectLinks.hostAndPort) == ["localhost:3000", "localhost:5173"])
        #expect(links.folder.path == "/Users/me/storefront")
        #expect(links.folder.hasDirectoryPath)
        #expect(ProjectLinks.terminalBundleID == "com.apple.Terminal")
    }

    @Test("A project with no ports has no links, only its folder")
    func noPorts() {
        let links = ProjectLinks(Project(rootPath: "/p", name: "p", servers: [Self.server(ports: [])]))
        #expect(links.urls.isEmpty)
        #expect(links.folder.path == "/p")
    }

    private func scannedModel() throws -> (StorageModel, [StorageNode]) {
        let scanner = SimulatedStorageScanner(stepDelay: .zero)
        let model = StorageModel(scanner: scanner)
        model.finish(scanner.makeScan())
        let rows = try #require(model.focus?.children)
        return (model, rows)
    }

    @Test("⌘⌫ asks to trash the selected row through the confirmation; nothing selected asks nothing")
    func trashSelection() throws {
        let (model, rows) = try scannedModel()
        model.trashSelection(in: rows)
        #expect(model.trashStep.pending == nil)
        let item = try #require(rows.first { $0.isItem })
        model.selectedID = item.id
        model.trashSelection(in: rows)
        let request = try #require(model.trashStep.pending)
        #expect(request.path == item.path)
        #expect(request.title.contains(item.name))
        model.trashStep.cancel()
    }

    @Test("⌘⌫ on a bucket of small files, or a selection no longer shown, asks nothing")
    func trashNotAnItem() throws {
        let (model, rows) = try scannedModel()
        model.selectedID = "/nowhere"
        model.trashSelection(in: rows)
        #expect(model.trashStep.pending == nil)
        if let bucket = rows.first(where: { !$0.isItem }) {
            model.selectedID = bucket.id
            model.trashSelection(in: rows)
            #expect(model.trashStep.pending == nil)
        }
    }

    @Test("Space opens Quick Look on the selected row, else the hovered one, and closes it again")
    func quickLook() throws {
        let (model, rows) = try scannedModel()
        let items = rows.filter(\.isItem)
        try #require(items.count >= 2)
        model.toggleQuickLook(in: rows)
        #expect(model.quickLookURL == nil)
        model.toggleQuickLook(in: rows, hovered: items[1])
        #expect(model.quickLookURL?.path == items[1].path)
        model.toggleQuickLook(in: rows)
        #expect(model.quickLookURL == nil)
        model.selectedID = items[0].id
        model.toggleQuickLook(in: rows, hovered: items[1])
        #expect(model.quickLookURL?.path == items[0].path)
    }

    @Test("Mute Alerts for an app adds it to the muted apps; Unmute takes it out")
    func mute() {
        let services = AppServices.preview()
        var saved: [Set<AppIdentity.ID>] = []
        services.setAlertsMuted(true, for: "com.example.hog")
        saved.append(services.alertSettings.mutedAppIDs)
        services.setAlertsMuted(true, for: "com.example.hog")
        saved.append(services.alertSettings.mutedAppIDs)
        services.setAlertsMuted(false, for: "com.example.hog")
        saved.append(services.alertSettings.mutedAppIDs)
        #expect(saved == [["com.example.hog"], ["com.example.hog"], []])
    }
}
