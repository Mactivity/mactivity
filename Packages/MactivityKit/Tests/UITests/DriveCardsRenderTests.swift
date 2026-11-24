import AppKit
import Core
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// The Disk tab's and Storage's new cards (D-281 to D-285), from made-up figures. Renders into
/// `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Drive cards renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct DriveCardsRenderTests {
    private let renderer = RoadmapRenderTests()

    private func app(_ name: String) -> AppIdentity {
        AppIdentity(id: name, name: name, bundleID: name, iconKey: name, kind: .app)
    }

    private func wearReport(startsLate: Bool = false, drive: DriveHealth? = nil) -> SSDWearReport {
        SSDWearReport(
            writers: [
                AppTotal(app: app("Claude Code"), value: 914e9), AppTotal(app: app("Claude"), value: 110e9),
                AppTotal(app: app("Google Chrome"), value: 50e9), AppTotal(app: app("Simulator"), value: 41e9),
                AppTotal(app: app("Safari"), value: 28e9), AppTotal(app: app("Ollama"), value: 11e9),
            ],
            allDrivesWritten: 3.33e12, since: Date().addingTimeInterval(-12 * 86400), startsLate: startsLate, internalDrive: drive
        )
    }

    @Test("What wears your SSD")
    func wear() async throws {
        let drive = await SimulatedDriveHealth().drives().first
        try renderer.write(
            SSDWearContent(report: wearReport(drive: drive)) { _ in }.padding(Tokens.Spacing.l), name: "ssd-wear", width: 760
        )
        try renderer.write(
            SSDWearContent(report: wearReport(startsLate: true)) { _ in }.padding(Tokens.Spacing.l), name: "ssd-wear-no-report", width: 760
        )
        try renderer.write(SSDWearContent(report: nil) { _ in }.padding(Tokens.Spacing.l), name: "ssd-wear-empty", width: 760)
    }

    @Test("External and network drives, filled and empty")
    func drives() async throws {
        let source = SimulatedMountedDrives()
        let external = await source.externalDrives()
        let network = await source.networkDrives()
        let filled = MountedDrivesModel(source: source, external: external, network: network, nfsRate: (reads: 4, writes: 1))
        try await renderer.writeInWindow(
            VStack(spacing: Tokens.Spacing.gridGutter) {
                ExternalDrivesCard(model: filled)
                NetworkDrivesCard(model: filled)
            }
            .padding(Tokens.Spacing.l),
            name: "drives-filled", size: CGSize(width: 760, height: 420)
        )
        let empty = SimulatedMountedDrives(external: [], network: [])
        let none = MountedDrivesModel(source: empty, external: [], network: [])
        try await renderer.writeInWindow(
            VStack(spacing: Tokens.Spacing.gridGutter) {
                ExternalDrivesCard(model: none)
                NetworkDrivesCard(model: none)
            }
            .padding(Tokens.Spacing.l),
            name: "drives-empty", size: CGSize(width: 760, height: 220)
        )
    }

    @Test("Photos library")
    func photos() async throws {
        UserDefaults.standard.set(true, forKey: PreferenceKey.photosLibraryExpanded)
        defer { UserDefaults.standard.removeObject(forKey: PreferenceKey.photosLibraryExpanded) }
        let measured = PhotosLibraryModel(source: SimulatedPhotosLibrary())
        try await renderer.writeInWindow(
            PhotosLibraryCard(model: measured).padding(Tokens.Spacing.l), name: "photos-measured", size: CGSize(width: 760, height: 320)
        )
        let closed = PhotosLibraryModel(source: SimulatedPhotosLibrary(reports: [
            PhotosLibraryReport(path: "/Users/you/Pictures/Photos Library.photoslibrary", state: .noAccess),
            PhotosLibraryReport(path: "/Volumes/Photos/Family.photoslibrary", state: .notMeasured),
        ]))
        try await renderer.writeInWindow(
            PhotosLibraryCard(model: closed).padding(Tokens.Spacing.l), name: "photos-closed", size: CGSize(width: 760, height: 260)
        )
    }

    @Test("Old app versions and leftovers")
    func oldApps() async throws {
        let rows = [
            FileCleanupSource.row(OldAppCopy(
                path: "/Applications/Writer Old.app", bundleID: "com.acme.Writer", name: "Writer", version: "2.9",
                keptPath: "/Applications/Writer.app", keptVersion: "2.10", size: 612_000_000
            )),
            FileCleanupSource.row(AppSupportLeftover(
                path: NSHomeDirectory() + "/Library/Application Support/com.gone.App", kind: .applicationSupport, owner: "com.gone.App",
                appName: "Gone Writer", matchedByName: false, size: 1_400_000_000, lastChanged: Date().addingTimeInterval(-400 * 86400),
                fileCount: 1832, contents: ["Backups", "Cache", "library.db", "settings.json"]
            )),
            FileCleanupSource.row(AppSupportLeftover(
                path: NSHomeDirectory() + "/Library/Caches/Gone Writer", kind: .caches, owner: "Gone Writer",
                appName: "Gone Writer", matchedByName: true, size: 88_000_000, lastChanged: Date().addingTimeInterval(-300 * 86400),
                fileCount: 40, contents: ["Cache.db"]
            )),
        ]
        let model = FileCleanupModel(.oldApps(recorded: RecordedAppsBox()), loaded: rows)
        try await renderer.writeInWindow(
            FileCleanupSheet(model: model, trasher: SimulatedStorageScanner().trasher) { _ in },
            name: "old-apps", size: CGSize(width: 600, height: 560)
        )
    }
}
