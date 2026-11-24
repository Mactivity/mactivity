import Core
import Foundation
import Testing

@Suite("Why is my Mac slow? (D-134)")
struct SlowdownTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func app(_ id: String, cpu: Double = 0, memory: UInt64 = 0, disk: Double = 0, gpu: Double? = nil) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: id, name: id, bundleID: id, iconKey: "", kind: .app),
            processCount: 1, cpuPercent: cpu, memoryBytes: memory, energyMW: nil, diskReadBPS: disk, diskWriteBPS: 0,
            netInBPS: nil, netOutBPS: nil, gpuPercent: gpu
        )
    }

    private func snapshot(
        _ index: Int = 0,
        cpu: Double = 10,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        thermal: ThermalPressure = .nominal,
        free: UInt64 = 400_000_000_000,
        disk: Double = 0,
        gpu: Double = 0,
        apps: [AppAggregate] = [],
        system: [(String, Double)] = []
    ) -> Snapshot {
        let processes = system.enumerated().map { offset, process in
            ProcessSample(
                pid: Int32(100 + offset), app: "system", name: process.0, cpuPercent: process.1, footprintBytes: 0,
                diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
            )
        }
        return Snapshot(
            at: Self.base.addingTimeInterval(Double(index)), interval: .seconds(1),
            system: SystemSample(
                // Ten cores: 10% of the Mac is one core.
                cpu: CPUStats(
                    totalPercent: cpu, userPercent: cpu, systemPercent: 0, perCorePercent: Array(repeating: cpu, count: 10),
                    clusters: [], loadAverage: .zero
                ),
                memory: MemoryStats(
                    totalBytes: 16_000_000_000, usedBytes: 8_000_000_000, appBytes: 6_000_000_000, wiredBytes: 0,
                    compressedBytes: 0, cachedFilesBytes: 0, swapUsedBytes: swap, pressure: pressure, availableLevel: 50
                ),
                disk: DiskStats(
                    volumes: [VolumeStats(id: "/", name: "Macintosh HD", totalBytes: 1_000_000_000_000, freeBytes: free)],
                    readBPS: disk, writeBPS: 0
                ),
                network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
                gpu: GPUStats(name: "Apple GPU", utilizationPercent: gpu, memoryInUseBytes: nil),
                battery: nil, sensors: nil, thermal: thermal, uptime: .seconds(3600)
            ),
            apps: apps, processes: processes, systemPIDs: Set(processes.map(\.pid))
        )
    }

    private func kinds(_ snapshots: [Snapshot], lowPower: Bool = false) -> [SlowdownCause.Kind] {
        Slowdown.diagnose(snapshots, lowPowerMode: lowPower).map(\.kind)
    }

    @Test("A quiet Mac: nothing to say")
    func quiet() {
        #expect(kinds([snapshot(), snapshot(1)]).isEmpty)
    }

    @Test("A busy processor names the apps using it, and each app using cores can be quit")
    func busyCPU() throws {
        let apps = [app("Xcode", cpu: 45), app("Safari", cpu: 20), app("Notes", cpu: 1)]
        let causes = Slowdown.diagnose([snapshot(cpu: 85, apps: apps), snapshot(1, cpu: 80, apps: apps)], lowPowerMode: false)
        #expect(causes.map(\.kind) == [.busyCPU, .busyApp, .busyApp])
        #expect(causes[0].title.contains("83%"))
        #expect(causes[0].detail.contains("Xcode"))
        // 45% of ten cores is 4.5 cores; Notes doesn't use enough to name.
        #expect(causes[1].title.contains("Xcode"))
        #expect(try causes[1].action == .quit(#require(causes[1].app)))
        #expect(causes[2].title.contains("Safari"))
    }

    @Test("One app spinning several cores is worth knowing even when the Mac copes")
    func busyAppAlone() {
        let causes = Slowdown.diagnose([snapshot(cpu: 30, apps: [app("Chrome Helper", cpu: 25)])], lowPowerMode: false)
        #expect(causes.map(\.kind) == [.busyApp])
        #expect(causes.first?.severity == .minor)
    }

    @Test("Memory pressure names the biggest apps; swap alone is worth knowing")
    func memory() {
        let apps = [app("Safari", memory: 6_000_000_000), app("Xcode", memory: 4_000_000_000)]
        let pressured = Slowdown.diagnose([snapshot(pressure: .warning, apps: apps)], lowPowerMode: false)
        #expect(pressured.map(\.kind) == [.memory])
        #expect(pressured.first?.detail.contains("Safari and Xcode") == true)
        #expect(kinds([snapshot(swap: 5_000_000_000)]) == [.swap])
    }

    @Test("Short of memory: apps open but unused for days are named too (D-135)")
    func unusedWhenShort() {
        let unused = [UnusedApp(
            app: AppIdentity(id: "Docker", name: "Docker", bundleID: nil, iconKey: "", kind: .app),
            memoryBytes: 2_000_000_000, lastUsed: nil, unusedFor: 5 * 86400
        )]
        let short = Slowdown.diagnose([snapshot(pressure: .warning)], lowPowerMode: false, unused: unused)
        #expect(short.map(\.kind) == [.memory, .unusedApps])
        #expect(short.last?.action == .showUnusedApps)
        // Plenty of memory: not a cause of slowness.
        #expect(Slowdown.diagnose([snapshot()], lowPowerMode: false, unused: unused).isEmpty)
    }

    @Test("Heat comes first, before everything else")
    func heat() {
        let causes = kinds([snapshot(cpu: 90, pressure: .warning, thermal: .serious, apps: [app("Game", cpu: 50)])])
        #expect(causes.first == .heat)
        #expect(causes.contains(.memory) && causes.contains(.busyCPU))
    }

    @Test("macOS's background jobs, from their processes: Spotlight, Time Machine, Photos")
    func backgroundJobs() {
        // 5% of ten cores is half a core for Spotlight; 2% (a fifth) for backupd isn't enough.
        let jobs = [("mds_stores", 3.0), ("mdworker_shared", 2.0), ("backupd", 2.0), ("photoanalysisd", 4.0)]
        #expect(kinds([snapshot(system: jobs), snapshot(1, system: jobs)]) == [.spotlight, .photos])
        // A process of an app with the same name isn't macOS's.
        let notSystem = snapshot(system: [("mds_stores", 9)])
        let asApp = Snapshot(
            at: notSystem.at, interval: notSystem.interval, system: notSystem.system, apps: [], processes: notSystem.processes
        )
        #expect(kinds([asApp]).isEmpty)
    }

    @Test("A full disk, a busy disk, a busy GPU, and Low Power Mode")
    func others() {
        #expect(kinds([snapshot(free: 8_000_000_000)]) == [.diskFull])
        #expect(kinds([snapshot(disk: 300_000_000, apps: [app("Photos", disk: 280_000_000)])]) == [.diskBusy])
        #expect(kinds([snapshot(gpu: 97, apps: [app("Final Cut Pro", gpu: 80)])]) == [.gpu])
        #expect(kinds([snapshot()], lowPower: true) == [.lowPower])
    }

    @Test("Figures are averaged over the window: one busy second isn't a busy Mac")
    func averaged() {
        let spike = [snapshot(cpu: 95), snapshot(1, cpu: 20), snapshot(2, cpu: 20)]
        #expect(kinds(spike).isEmpty)
    }
}
