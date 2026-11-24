import AppKit
import Core
import os
import SwiftUI

/// `-MeasureDemoTour YES` (scripts/demo-video.sh, D-124), always with simulated data and
/// screenshot mode: the main window walks through the tabs on a timer with a caption for each,
/// then Mactivity quits, so a recorder can film it without anyone touching the Mac. Launch
/// argument only; captions are English, for the video.
/// `-MeasureDemoClip <name>` plays just the steps with that clip name, for the short clips
/// `make media` films (scripts/media.sh).
enum DemoTour {
    static let log = Logger(subsystem: "app.mactivity.ui", category: "demo")

    struct Step {
        /// The clip this step belongs to, for `-MeasureDemoClip`.
        let clip: String
        let item: SidebarItem
        let caption: String
        let seconds: Double
        /// Opens "Why is my Mac slow?" over the tab for this step.
        var diagnose = false
    }

    /// The demo's busy moment for "Why is my Mac slow?": the simulated Mac, with Xcode building,
    /// memory running short and Spotlight indexing. Sample data, like everything in the demo;
    /// the real app only ever diagnoses real snapshots.
    static func busyMoment(_ base: Snapshot) -> [Snapshot] {
        let cores = max(1, base.system.cpu.perCorePercent.count)
        let xcode = AppIdentity(
            id: "com.apple.dt.Xcode", name: "Xcode", bundleID: "com.apple.dt.Xcode",
            iconKey: "/Applications/Xcode.app", kind: .app
        )
        let building = AppAggregate(
            app: xcode, processCount: 14, cpuPercent: 300 / Double(cores), memoryBytes: 6_400_000_000, energyMW: 9000,
            diskReadBPS: 0, diskWriteBPS: 20_000_000, netInBPS: 0, netOutBPS: 0, gpuPercent: 0
        )
        let spotlight = ProcessSample(
            pid: 99001, app: AppIdentity.system.id, name: "mds_stores", cpuPercent: 60 / Double(cores), footprintBytes: 300_000_000,
            diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
        let system = base.system
        let cpu = CPUStats(
            totalPercent: 84, userPercent: 70, systemPercent: 14, perCorePercent: system.cpu.perCorePercent.map { _ in 84 },
            clusters: system.cpu.clusters, loadAverage: system.cpu.loadAverage
        )
        let memory = system.memory
        let short = MemoryStats(
            totalBytes: memory.totalBytes, usedBytes: memory.totalBytes / 10 * 9, appBytes: memory.appBytes, wiredBytes: memory.wiredBytes,
            compressedBytes: memory.compressedBytes, cachedFilesBytes: memory.cachedFilesBytes, swapUsedBytes: 2_100_000_000,
            pressure: .warning, availableLevel: 12
        )
        let sample = SystemSample(
            cpu: cpu, memory: short, disk: system.disk, network: system.network, gpu: system.gpu, battery: system.battery,
            sensors: system.sensors, thermal: system.thermal, uptime: system.uptime
        )
        let apps = [building] + base.apps.filter { $0.id != xcode.id }
        return (1 ... 3).map { second in
            Snapshot(
                at: base.at.addingTimeInterval(Double(second)), interval: .seconds(1), system: sample, apps: apps,
                processes: base.processes + [spotlight], systemPIDs: base.systemPIDs.union([spotlight.pid])
            )
        }
    }

    /// The whole tour, or one clip's steps with `-MeasureDemoClip <name>`.
    static var selectedSteps: [Step] {
        guard let clip = UserDefaults.standard.string(forKey: "MeasureDemoClip") else {
            return steps
        }
        return steps.filter { $0.clip == clip }
    }

    /// "Why is my Mac slow?" watches for about 9 s before it answers; its step holds long enough
    /// for the answer to stay on screen.
    static let steps: [Step] = [
        Step(clip: "glance", item: .overview, caption: "Mactivity: your whole Mac at a glance", seconds: 6),
        Step(clip: "why-slow", item: .overview, caption: "Why is my Mac slow? Answered in one click", seconds: 14, diagnose: true),
        Step(clip: "apps", item: .cpu, caption: "Helpers and background processes, added up per app", seconds: 6),
        Step(clip: "metrics", item: .memory, caption: "Memory, disk, network and GPU, app by app", seconds: 5),
        Step(clip: "battery", item: .battery, caption: "Battery use by app, like on iPhone", seconds: 5),
        Step(clip: "history", item: .history, caption: "A year of history, kept on your Mac", seconds: 6),
        Step(clip: "checkup", item: .checkup, caption: "Checkup: what's worth doing", seconds: 6),
        Step(clip: "storage", item: .storage, caption: "See what's using your disk, and get space back", seconds: 7),
        Step(clip: "projects", item: .projects, caption: "Dev servers and ports, for developers", seconds: 4),
        Step(clip: "alerts", item: .alerts, caption: "Alerts when an app misbehaves", seconds: 5),
        Step(clip: "outro", item: .overview, caption: "Mactivity · mactivity.app · Free and open source", seconds: 4),
    ]
}

/// The caption bar and the timer that drives the tour.
struct DemoTourModifier: ViewModifier {
    let services: AppServices
    @State private var caption = ""

    func body(content: Content) -> some View {
        if LaunchOverrides.isDemoTour {
            content
                .overlay(alignment: .bottom) {
                    if !caption.isEmpty {
                        Text(verbatim: caption)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Tokens.Spacing.l)
                            .padding(.vertical, Tokens.Spacing.s)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.bottom, Tokens.Spacing.l)
                            .transition(.opacity)
                            .id(caption)
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: caption)
                .task { await run() }
        } else {
            content
        }
    }

    private func run() async {
        // `-MeasureDemoReadyFile <path>` (scripts/media.sh): the recorder creates the file once it's
        // filming, so every clip starts at its beginning however long the window took to settle.
        if let ready = UserDefaults.standard.string(forKey: "MeasureDemoReadyFile") {
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        DemoTour.log.notice("Demo tour starting")
        // Simulated history and charts settle first.
        try? await Task.sleep(for: .seconds(2))
        for step in DemoTour.selectedSteps {
            DemoTour.log.notice("Demo tour: \(step.item.rawValue, privacy: .public)")
            services.navigation.selection = step.item
            caption = step.caption
            if step.diagnose {
                services.slowdown.open(services)
            }
            // A clip on its own holds longer than the same step inside the tour.
            let clip = UserDefaults.standard.string(forKey: "MeasureDemoClip") != nil
            try? await Task.sleep(for: .seconds(step.seconds + (clip ? 3 : 0)))
            if step.diagnose {
                services.slowdown.close()
            }
        }
        caption = ""
        try? await Task.sleep(for: .seconds(1))
        DemoTour.log.notice("Demo tour done; quitting")
        // On the next turn of the run loop, not from inside this task: quitting waits for the
        // history flush, which needs the main actor this task is holding.
        NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
