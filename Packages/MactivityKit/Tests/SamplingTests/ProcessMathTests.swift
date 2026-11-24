import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Process rate math")
struct ProcessMathTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let now = Date(timeIntervalSince1970: 1_000_100)
    let app = AppIdentity(id: "com.example.App", name: "App", bundleID: "com.example.App", iconKey: "/Applications/App.app", kind: .app)

    func reading(
        pid: Int32 = 10, start: Date? = nil, cpu: Duration = .zero, write: UInt64 = 0, energy: UInt64 = 0, complete: Bool = true
    ) -> ProcessReading {
        ProcessReading(
            pid: pid, parentPID: 1, uid: 501, name: "App", executablePath: nil, startTime: start ?? self.start,
            cpuTime: cpu, footprintBytes: 5_000_000, diskReadBytes: 0, diskWriteBytes: write, energyNJ: energy,
            isComplete: complete
        )
    }

    func run(
        previous: [ProcessReading],
        current: [ProcessReading],
        gpuBefore: [Int32: UInt64] = [:],
        gpuNow: [Int32: UInt64] = [:],
        elapsed: Duration = .seconds(5),
        cores: Int = 10
    ) -> [ProcessSample] {
        ProcessMath.samples(
            previous: Dictionary(uniqueKeysWithValues: previous.map { ($0.pid, $0) }), current: current,
            identities: [10: app], previousGPU: gpuBefore, currentGPU: gpuNow, elapsed: elapsed, now: now, coreCount: cores
        )
    }

    @Test("CPU percent is CPU time over wall time over cores")
    func cpu() {
        // 10 s of CPU in 5 s on 10 cores = 20% of the machine.
        let result = run(previous: [reading(cpu: .seconds(100))], current: [reading(cpu: .seconds(110))])
        #expect(abs(result[0].cpuPercent - 20) < 0.0001)
        #expect(result[0].app == app.id)
    }

    @Test("Disk and energy rates")
    func rates() {
        let result = run(
            previous: [reading(write: 1_000_000, energy: 1_000_000_000)],
            current: [reading(write: 6_000_000, energy: 6_000_000_000)]
        )
        #expect(result[0].diskWriteBPS == 1_000_000)
        // 5e9 nJ in 5 s = 1 W = 1000 mW.
        #expect(abs((result[0].energyMW ?? 0) - 1000) < 0.0001)
    }

    @Test("A reused PID with a new start time is a new process")
    func pidReuse() {
        let result = run(
            previous: [reading(cpu: .seconds(100))],
            current: [reading(start: Date(timeIntervalSince1970: 900_000), cpu: .seconds(101))]
        )
        #expect(result[0].cpuPercent == 0)
    }

    @Test("A process that started during the interval is rated over its age")
    func newProcess() {
        // Started 2 s before now, used 1 s of CPU: 50% of one core = 5% of 10 cores.
        let result = run(previous: [], current: [reading(start: now.addingTimeInterval(-2), cpu: .seconds(1))])
        #expect(abs(result[0].cpuPercent - 5) < 0.0001)
    }

    @Test("A process only milliseconds old isn't rated over its millisecond age")
    func veryYoungProcess() {
        // Launched 1 ms before the sample, with 5 ms of CPU and 300 wakeups already: over 1 ms that
        // reads as 500% CPU and an Energy Impact near 6,500. Over the 1 s minimum it's 0.5%, ~6.5.
        let young = ProcessReading(
            pid: 11, parentPID: 1, uid: 501, name: "clang", executablePath: nil, startTime: now.addingTimeInterval(-0.001),
            cpuTime: .milliseconds(5), footprintBytes: 1_000_000, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0,
            isComplete: true, wakeups: 300
        )
        let result = run(previous: [], current: [young])
        #expect(result[0].cpuPercent < 0.1)
        #expect((result[0].energyImpact ?? .infinity) < 10)
    }

    @Test("A process seen for the first time that is older than the interval reads zero")
    func firstSightOld() {
        let result = run(previous: [], current: [reading(cpu: .seconds(500))])
        #expect(result[0].cpuPercent == 0)
    }

    @Test("Incomplete readings have no energy figure")
    func incomplete() {
        let result = run(previous: [reading(complete: false)], current: [reading(complete: false)])
        #expect(result[0].energyMW == nil)
    }

    @Test("GPU percent from accumulated GPU nanoseconds; nil when unavailable")
    func gpu() {
        let withGPU = run(previous: [reading()], current: [reading()], gpuBefore: [10: 1_000_000_000], gpuNow: [10: 2_000_000_000])
        #expect(abs((withGPU[0].gpuPercent ?? -1) - 20) < 0.0001)
        let without = run(previous: [reading()], current: [reading()])
        #expect(without[0].gpuPercent == nil)
    }

    @Test("Counters going backwards read as zero, not negative")
    func backwards() {
        let result = run(previous: [reading(write: 9_000_000)], current: [reading(write: 1_000_000)])
        #expect(result[0].diskWriteBPS == 0)
    }

    @Test("Unknown PIDs are attributed to Other by name")
    func unknown() {
        let result = run(previous: [], current: [reading(pid: 99)])
        #expect(result[0].app == "other:App")
    }
}

@Suite("Process sampler (live)")
struct ProcessSamplerTests {
    @Test("Reads this process, completely, with a path and CPU time")
    func readsSelf() async throws {
        let readings = try await ProcessSampler().sample()
        let me = try #require(readings.first { $0.pid == getpid() })
        #expect(me.isComplete)
        #expect(me.executablePath != nil)
        #expect(me.footprintBytes > 0)
        #expect(me.cpuTime > .zero)
        #expect(readings.count > 50)
    }

    @Test("A full pass is cheap")
    func timing() async throws {
        let sampler = ProcessSampler()
        _ = try await sampler.sample()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for _ in 0 ..< 10 {
                _ = try await sampler.sample()
            }
        }
        // Debug build; the release figure is lower. Guard against regressions, not a budget.
        #expect(elapsed / 10 < .milliseconds(50))
    }
}

@Suite("Process rate math across skipped readings")
struct ProcessMathSkipTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func reading(cpu: Duration, complete: Bool) -> ProcessReading {
        ProcessReading(
            pid: 7, parentPID: 1, uid: 0, name: "daemon", executablePath: "/usr/libexec/daemon", startTime: start,
            cpuTime: complete ? cpu : .zero, footprintBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0,
            isComplete: complete
        )
    }

    @Test("Going from a skipped reading back to a full one doesn't spike")
    func noSpike() {
        let result = ProcessMath.samples(
            previous: [7: reading(cpu: .zero, complete: false)], current: [reading(cpu: .seconds(5000), complete: true)],
            identities: [:], previousGPU: [:], currentGPU: [:], elapsed: .seconds(1),
            now: start.addingTimeInterval(100_000), coreCount: 10
        )
        #expect(result[0].cpuPercent == 0)
    }
}

@Suite("Process rate math on the first pass")
struct ProcessMathFirstPassTests {
    @Test("Zero elapsed time lists every process at zero rates")
    func firstPass() {
        let reading = ProcessReading(
            pid: 3, parentPID: 1, uid: 501, name: "x", executablePath: nil, startTime: Date(timeIntervalSince1970: 0),
            cpuTime: .seconds(9), footprintBytes: 10, diskReadBytes: 5, diskWriteBytes: 5, energyNJ: 5, isComplete: true
        )
        let result = ProcessMath.samples(
            previous: [:], current: [reading], identities: [:], previousGPU: [:], currentGPU: [:], elapsed: .zero,
            now: Date(timeIntervalSince1970: 100), coreCount: 4
        )
        #expect(result.count == 1)
        #expect(result[0].cpuPercent == 0)
        #expect(result[0].footprintBytes == 10)
    }
}

@Suite("Energy Impact in process math")
struct ProcessEnergyImpactTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func reading(cpu: Duration, wakeups: UInt64) -> ProcessReading {
        ProcessReading(
            pid: 5, parentPID: 1, uid: 501, name: "x", executablePath: nil, startTime: start, cpuTime: cpu, footprintBytes: 0,
            diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: true, wakeups: wakeups
        )
    }

    @Test("Half a core plus 1,000 wakeups over 2 s scores 50 + 10")
    func impact() throws {
        let result = ProcessMath.samples(
            previous: [5: reading(cpu: .seconds(10), wakeups: 100)], current: [reading(cpu: .seconds(11), wakeups: 1100)],
            identities: [:], previousGPU: [:], currentGPU: [:], elapsed: .seconds(2), now: start.addingTimeInterval(100),
            coreCount: 10, energy: .builtIn
        )
        let impact = try #require(result.first?.energyImpact)
        #expect(abs(impact - 60) < 1e-6)
    }

    @Test("The shipped coefficients load on this Mac, or fall back to the built-in ones")
    func loader() {
        let missing = EnergyCoefficientsLoader.load(directory: URL(fileURLWithPath: "/nonexistent"), boardID: nil)
        #expect(missing == .builtIn)
        #expect(EnergyCoefficientsLoader.current.cpuTime == 1)
    }

    @Test("The exec path from a KERN_PROCARGS2 buffer, for processes proc_pidpath refuses (D-111)")
    func execPath() {
        let path = "/Applications/Microsoft Excel.app/Contents/PlugIns/ExcelWidget_mac.appex/Contents/MacOS/ExcelWidget_mac"
        let bytes: [UInt8] = [1, 0, 0, 0] + Array(path.utf8) + [0, 0, 0] + Array("ExcelWidget_mac".utf8) + [0]
        #expect(ProcessSampler.execPath(procArgs: bytes) == path)
        #expect(ProcessSampler.execPath(procArgs: [1, 0, 0, 0] + Array("relative".utf8) + [0]) == nil)
        #expect(ProcessSampler.execPath(procArgs: [1, 0]) == nil)
    }
}
