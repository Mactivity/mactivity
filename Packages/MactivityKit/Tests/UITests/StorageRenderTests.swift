import AppKit
import Core
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// Renders the Storage tab with simulated data, light and dark, into `MACTIVITY_SNAPSHOT_DIR`.
/// Runs only when that's set (`make snapshots M=E10`). Tables, lists, and pickers are AppKit
/// underneath, which `ImageRenderer` can't draw, so this hosts the view in an offscreen window.
@MainActor
@Suite("Storage renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct StorageRenderTests {
    init() {
        _ = PseudoLocalization.isOn
    }

    private static let size = CGSize(width: 900, height: 740)

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private func model(access: FullDiskAccessStatus = .granted, tab: StorageModel.Tab = .map) async -> StorageModel {
        let scanner = SimulatedStorageScanner(fullDiskAccess: access, stepDelay: .zero)
        let model = StorageModel(scanner: scanner)
        model.appeared()
        model.finish(scanner.makeScan())
        model.tab = tab
        for _ in 0 ..< 100 where model.isLoadingLens {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    private func write(_ model: StorageModel, name: String, size: CGSize = size) throws {
        UserDefaults.standard.removeObject(forKey: "storage.fullDiskAccessExplainerDismissed")
        _ = NSApplication.shared
        for dark in [false, true] {
            let view = StorageView(model: model, confirmedAction: ConfirmedAction(terminator: SimulatedDevServers()))
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    @Test("Map tab")
    func map() async throws {
        try await write(model(), name: "storage-map")
    }

    @Test("Map tab zoomed into Library and hovering DerivedData, with the Full Disk Access explainer")
    func zoomedWithExplainer() async throws {
        let model = await model(access: .denied)
        if let library = model.scan?.root.children.first(where: { $0.name == "Library" }) {
            model.zoom(to: library)
        }
        model.hovered = model.segments.first { $0.node?.name == "DerivedData" }
        try write(model, name: "storage-map-library", size: CGSize(width: 900, height: 860))
    }

    @Test("A short window: the map draws smaller, the categories' note wraps (D-172)")
    func shortWindow() async throws {
        try await write(model(), name: "storage-map-short", size: CGSize(width: 800, height: 470))
        try await write(model(tab: .categories), name: "storage-categories-short", size: CGSize(width: 800, height: 470))
    }

    @Test("Categories tab")
    func categories() async throws {
        try await write(model(tab: .categories), name: "storage-categories")
    }

    @Test("Developer tab")
    func developer() async throws {
        try await write(model(tab: .developer), name: "storage-developer")
    }

    @Test("Largest files tab")
    func largest() async throws {
        try await write(model(tab: .largest), name: "storage-largest")
    }

    @Test("Full Disk Access denied, in the minimum and a short window, before and after a scan (D-177)")
    func accessDenied() async throws {
        let empty = StorageModel(scanner: SimulatedStorageScanner(fullDiskAccess: .denied, stepDelay: .zero))
        empty.appeared()
        let scanned = await model(access: .denied)
        // The detail area of a minimum-size and a 1000 × 640 window.
        for (size, suffix) in [(CGSize(width: 560, height: 468), "minimum"), (CGSize(width: 800, height: 588), "short")] {
            try write(empty, name: "storage-denied-empty-\(suffix)", size: size)
            try write(scanned, name: "storage-denied-scanned-\(suffix)", size: size)
        }
    }

    @Test("Before the first scan")
    func empty() throws {
        let model = StorageModel(scanner: SimulatedStorageScanner(stepDelay: .zero))
        model.appeared()
        try write(model, name: "storage-empty", size: CGSize(width: 900, height: 520))
    }
}
