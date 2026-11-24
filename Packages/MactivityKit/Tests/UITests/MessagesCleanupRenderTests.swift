import AppKit
import Core
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// Renders the Messages attachments sheet (D-116), light and dark, into `MACTIVITY_SNAPSHOT_DIR`
/// (`make snapshots M=messages FILTER=MessagesCleanupRenderTests`), with made-up attachments.
@MainActor
@Suite("Messages cleanup renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct MessagesCleanupRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private static func fixture() -> [MessageAttachment] {
        let now = Date()
        let names = [
            ("IMG_4411.MOV", 412, 900), ("Screen Recording 2024-03-02.mov", 288, 700), ("IMG_2210.HEIC", 3, 500),
            ("Tahoe trip.mp4", 190, 420), ("IMG_0932.JPG", 2, 400), ("Audio Message.caf", 1, 380),
            ("Lease.pdf", 4, 800), ("IMG_7781.HEIC", 3, 30), ("IMG_7782.MOV", 96, 12),
        ]
        return names.map { name, mb, days in
            MessageAttachment(
                path: "/Users/me/Library/Messages/Attachments/ab/12/\(UUID().uuidString)/\(name)",
                size: UInt64(mb) * 1_000_000, date: now.addingTimeInterval(-Double(days) * 86400),
                kind: MessagesAttachments.kind(pathExtension: (name as NSString).pathExtension)
            )
        }.sorted { $0.size > $1.size }
    }

    @Test("The backups sheet: two backups, one update")
    func backups() async throws {
        let now = Date()
        let scan = DeviceBackupsScan(
            backups: [
                DeviceBackup(
                    path: "/b/1", deviceName: "Kade's iPhone", productName: "iPhone 17 Pro", systemVersion: "26.0",
                    date: now.addingTimeInterval(-2 * 86400), size: 61_000_000_000, isEncrypted: true
                ),
                DeviceBackup(
                    path: "/b/2", deviceName: "Old iPad", productName: "iPad Air", systemVersion: "17.5",
                    date: now.addingTimeInterval(-700 * 86400), size: 23_000_000_000, isEncrypted: false
                ),
            ],
            updates: [DeviceUpdateFile(path: "/u/iPhone18,1_26.0_Restore.ipsw", size: 9_800_000_000, date: now)]
        )
        try await write(
            DeviceBackupsSheet(model: DeviceBackupsModel(loaded: scan), trasher: StorageTrasher(home: "/nonexistent")) { _ in },
            name: "device-backups", size: CGSize(width: 600, height: 520)
        )
    }

    @Test("The Downloads sheet: old installers ticked, a recent one not")
    func downloads() async throws {
        let now = Date()
        let items = [
            DownloadLeftover(path: "/d/Xcode_27.xip", kind: .archive, size: 11_400_000_000, added: now.addingTimeInterval(-60 * 86400)),
            DownloadLeftover(path: "/d/Docker.dmg", kind: .diskImage, size: 640_000_000, added: now.addingTimeInterval(-120 * 86400)),
            DownloadLeftover(path: "/d/Zoom.pkg", kind: .installer, size: 190_000_000, added: now.addingTimeInterval(-3 * 86400)),
        ]
        let rows = items.map {
            FileCleanupRow(
                path: $0.path, detail: FileCleanupSource.downloadDetail($0), size: $0.size,
                startsTicked: DownloadsLeftovers.startsTicked($0, now: now)
            )
        }
        try await write(
            FileCleanupSheet(model: FileCleanupModel(.downloads, loaded: rows), trasher: StorageTrasher(home: "/nonexistent")) { _ in },
            name: "downloads-cleanup", size: CGSize(width: 600, height: 440)
        )
        try await write(
            FileCleanupSheet(model: FileCleanupModel(.mail, loaded: [
                FileCleanupRow(path: "/m/A/Photos.zip", detail: "Saved Jun 3, 2026", size: 420_000_000, startsTicked: true),
                FileCleanupRow(path: "/m/B/Invoice.pdf", detail: "Saved Sep 28, 2026", size: 300_000, startsTicked: false),
            ]), trasher: StorageTrasher(home: "/nonexistent")) { _ in },
            name: "mail-cleanup", size: CGSize(width: 600, height: 420)
        )
    }

    @Test("Reclaimable: four cleanups and the Trash; Settings → Privacy")
    func reclaimable() async throws {
        let value = Reclaimable(
            messages: 6_200_000_000,
            backups: Reclaimable.Backups(bytes: 23_000_000_000, oldest: Date().addingTimeInterval(-700 * 86400)),
            downloads: 12_100_000_000, mail: 480_000_000, developer: 6_400_000_000, trash: 14_000_000_000
        )
        defer { UserDefaults.standard.removeObject(forKey: PreferenceKey.reclaimableExpanded) }
        for open in [false, true] {
            UserDefaults.standard.set(open, forKey: PreferenceKey.reclaimableExpanded)
            try await write(
                ReclaimableCard(cleanups: StorageCleanups(measured: value)).padding(),
                name: open ? "reclaimable-open" : "reclaimable", size: CGSize(width: 860, height: 240)
            )
        }
        try await write(
            PrivacySettings(controls: AppControls()), name: "settings-privacy", size: CGSize(width: 560, height: 560)
        )
    }

    @Test("Purgeable space: iCloud downloads and a snapshot")
    func purgeable() async throws {
        let model = PurgeableModel(
            downloads: [
                ICloudDownload(path: "/i/Pages/Documents/Thesis.pages", place: "Pages", size: 1_900_000_000),
                ICloudDownload(path: "/i/CloudDocs/Wedding.mov", place: "iCloud Drive", size: 1_200_000_000),
            ],
            snapshots: [Date().addingTimeInterval(-3 * 3600)]
        )
        try await write(
            PurgeableSheet(model: model, purgeable: 21_000_000_000) { _ in },
            name: "purgeable",
            size: CGSize(width: 600, height: 560)
        )
    }

    @Test("1.6: big files you forgot, duplicates, and cloud folders")
    func yourDisk() async throws {
        let old = Date().addingTimeInterval(-500 * 86400)
        let forgotten = [
            ForgottenFile(path: "/Users/kade/Movies/Exports/Wedding final.mov", size: 18_400_000_000, lastTouched: old),
            ForgottenFile(path: "/Users/kade/Documents/Old Mac backup.zip", size: 6_100_000_000, lastTouched: old),
        ].map { FileCleanupRow(path: $0.path, detail: FileCleanupSource.forgottenDetail($0), size: $0.size, startsTicked: false) }
        try await write(
            FileCleanupSheet(model: FileCleanupModel(.forgotten, loaded: forgotten), trasher: StorageTrasher(home: "/nonexistent")) { _ in
            },
            name: "forgotten-cleanup", size: CGSize(width: 600, height: 420)
        )
        try await write(
            FileCleanupSheet(model: FileCleanupModel(.duplicates, loaded: [
                FileCleanupRow(
                    path: "/Users/kade/Downloads/IMG_2041.mov",
                    detail: "Same as ~/Movies/IMG_2041.mov",
                    size: 2_300_000_000,
                    startsTicked: true
                ),
                FileCleanupRow(
                    path: "/Users/kade/Desktop/Deck v2.key",
                    detail: "Same as ~/Documents/Deck v2.key",
                    size: 410_000_000,
                    startsTicked: false
                ),
            ]), trasher: StorageTrasher(home: "/nonexistent")) { _ in },
            name: "duplicates-cleanup", size: CGSize(width: 600, height: 420)
        )
        let iCloud = CloudFolder(name: "iCloud Drive", path: "/i", isICloud: true)
        let dropbox = CloudFolder(name: "Dropbox", path: "/d", isICloud: false)
        let model = CloudFoldersModel(usages: [
            CloudFolderUsage(folder: iCloud, localBytes: 3_800_000_000, downloads: [
                ICloudDownload(path: "/i/CloudDocs/Videos/Trip.mov", place: "iCloud Drive", size: 1_200_000_000),
                ICloudDownload(path: "/i/CloudDocs/Scans/Taxes 2023.pdf", place: "iCloud Drive", size: 48_000_000),
            ]),
            CloudFolderUsage(folder: dropbox, localBytes: 9_700_000_000, downloads: [
                ICloudDownload(path: "/d/Team/Footage/Interview.mp4", place: "Dropbox", size: 4_100_000_000),
            ]),
        ])
        try await write(CloudFoldersSheet(model: model) { _ in }, name: "cloud-folders", size: CGSize(width: 620, height: 600))
    }

    @Test("1.6: two Macs side by side")
    func compareMacs() async throws {
        func mac(_ name: String, _ model: String, _ chip: String, cpu: Double, memory: Double, battery: Double?) -> MacProfile {
            MacProfile(
                name: name, model: model, chip: chip, memory: 36_000_000_000, disk: 1_000_000_000_000, cores: 14, system: "macOS 26.1",
                hasBattery: battery != nil, days: 30, start: Date().addingTimeInterval(-30 * 86400), end: Date(),
                figures: MacProfile.Figures(
                    cpuAverage: cpu, cpuBusy: cpu * 2.6, memoryAverage: memory, memoryPeak: memory * 1.4, pressureAverage: 31,
                    swapAverage: 1.2e9, gpuAverage: 12, hotShare: 0.02, onBatteryShare: battery, writtenPerDay: 24e9,
                    downloadedPerDay: 3.1e9, diskFree: 410e9, cpuApps: ["Xcode", "Safari"], memoryApps: ["Safari"]
                )
            )
        }
        let model = CompareMacsModel(
            this: mac("Studio", "Mac Studio", "Apple M4 Max", cpu: 14, memory: 22e9, battery: nil),
            other: mac("Kade's MacBook Pro", "MacBook Pro", "Apple M2 Pro", cpu: 31, memory: 24e9, battery: 0.3)
        )
        try await write(CompareMacsSheet(model: model), name: "compare-macs", size: CGSize(width: 640, height: 600))
    }

    @Test("The sheet with attachments, filtered to older than a year")
    func sheet() async throws {
        let model = MessagesCleanupModel(loaded: Self.fixture())
        try await write(
            MessagesCleanupSheet(model: model, trasher: StorageTrasher(home: "/nonexistent")) { _ in },
            name: "messages-cleanup", size: CGSize(width: 640, height: 640)
        )
    }

    /// Lets AppKit lay out and draw. Synchronous: `RunLoop.run` isn't available from async code.
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func write(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let framed = view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: framed)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    @Test("Outdated Software (D-252)")
    func outdatedSoftware() async throws {
        let defaults = UserDefaults(suiteName: "render-software") ?? .standard
        defaults.removePersistentDomain(forName: "render-software")
        defaults.set(true, forKey: PreferenceKey.checksVulnerabilities)
        let model = OutdatedSoftwareModel(source: SimulatedInstalledSoftware(), defaults: defaults)
        await model.refresh(force: true)
        try await write(OutdatedSoftwareSheet(model: model), name: "outdated-software", size: CGSize(width: 600, height: 560))
    }

    @Test("Looking back (D-254)")
    func lookingBack() async throws {
        func app(_ name: String, _ hours: Double) -> AppTotal {
            AppTotal(app: AppIdentity(id: name, name: name, bundleID: nil, iconKey: "other", kind: .app), value: hours * 3600)
        }
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)) ?? Date()
        let month = PeriodRecap(
            span: .month, interval: DateInterval(start: start, duration: 29 * 86400), activeSeconds: 162 * 3600,
            previousActiveSeconds: 140 * 3600,
            busiestDays: [DayTotal(day: start.addingTimeInterval(13 * 86400), seconds: 11.2 * 3600)], busiestMonth: nil,
            topApps: [app("Xcode", 61), app("Safari", 34), app("Ghostty", 21), app("Figma", 9), app("Slack", 7)],
            came: [app("Figma", 9)], went: [app("Zoom", 0)], agentSeconds: 74 * 3600, topAgentProject: "mactivity",
            slowdowns: 6, crashes: 2, dataBytes: 212e9, writtenBytes: 1.9e12, notes: 3, recordingSince: nil
        )
        try await write(RecapImageView(recap: month), name: "looking-back-month", size: CGSize(width: 720, height: 520))
        let year = PeriodRecap(
            span: .year,
            interval: DateInterval(start: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? start, end: start),
            activeSeconds: 1480 * 3600, previousActiveSeconds: nil,
            busiestDays: [DayTotal(day: start.addingTimeInterval(-40 * 86400), seconds: 13.1 * 3600)],
            busiestMonth: DayTotal(day: start.addingTimeInterval(-61 * 86400), seconds: 188 * 3600),
            topApps: [app("Xcode", 520), app("Safari", 301), app("Ghostty", 190)], came: [], went: [], agentSeconds: 410 * 3600,
            topAgentProject: "mactivity", slowdowns: 41, crashes: nil, dataBytes: 2.1e12, writtenBytes: 19e12, notes: 12,
            recordingSince: start.addingTimeInterval(-200 * 86400)
        )
        try await write(RecapImageView(recap: year), name: "looking-back-year", size: CGSize(width: 720, height: 480))
    }
}
