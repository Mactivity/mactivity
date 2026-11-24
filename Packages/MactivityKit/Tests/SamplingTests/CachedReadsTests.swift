import Core
import Foundation
import notify
@testable import Sampling
import Testing

@Suite("Cached reads: notify-guarded values, GPU walks (D-086)")
struct CachedReadsTests {
    let start = ContinuousClock.now

    @Test("A notify-guarded value is read first, after a post, and after its maximum age; otherwise reused")
    func needsRead() {
        let maxAge = Duration.seconds(30)
        #expect(NotifyWatch.needsRead(posted: false, lastRead: nil, now: start, maxAge: maxAge))
        #expect(!NotifyWatch.needsRead(posted: false, lastRead: start, now: start + .seconds(29), maxAge: maxAge))
        #expect(NotifyWatch.needsRead(posted: true, lastRead: start, now: start + .seconds(1), maxAge: maxAge))
        #expect(NotifyWatch.needsRead(posted: false, lastRead: start, now: start + .seconds(30), maxAge: maxAge))
    }

    @Test("A watch reports a post of its name, once")
    func watchSeesPost() async throws {
        let name = "app.mactivity.tests.\(UUID().uuidString)"
        let watch = NotifyWatch(name)
        _ = watch.posted() // the first check reports true
        #expect(!watch.posted())
        #expect(notify_post(name) == NOTIFY_STATUS_OK)
        // notifyd delivers asynchronously.
        var seen = false
        for _ in 0 ..< 100 where !seen {
            seen = watch.posted()
            if !seen {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(seen)
        #expect(!watch.posted())
    }

    @Test("GPU % between walks: nanoseconds over the walk's span, 0 for a new or different process")
    func gpuPercents() {
        let born = Date(timeIntervalSince1970: 1000)
        let reborn = Date(timeIntervalSince1970: 2000)
        let percents = ProcessMath.gpuPercents(
            previous: [1: 1_000_000_000, 2: 5_000_000_000, 3: 0],
            current: [1: 1_600_000_000, 2: 4_000_000_000, 3: 900_000_000, 4: 10],
            previousStarts: [1: born, 2: born, 3: born],
            currentStarts: [1: born, 2: born, 3: reborn, 4: born],
            elapsed: .seconds(3)
        )
        #expect(abs((percents[1] ?? -1) - 20) < 0.0001) // 0.6 s of GPU over 3 s
        #expect(percents[2] == 0) // the sum dropped
        #expect(percents[3] == 0) // PID reused
        #expect(percents[4] == 0) // new
        let first = ProcessMath.gpuPercents(
            previous: [:], current: [1: 5], previousStarts: [:], currentStarts: [1: born], elapsed: .zero
        )
        #expect(first == [1: 0])
    }

    @Test("Precomputed GPU % fills samples, and missing processes read 0")
    func samplesUseGPUPercents() {
        let born = Date(timeIntervalSince1970: 1000)
        func reading(_ pid: Int32, cpu: Duration) -> ProcessReading {
            ProcessReading(
                pid: pid, parentPID: 1, uid: 501, name: "p", executablePath: nil, startTime: born, cpuTime: cpu,
                footprintBytes: 1, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: true
            )
        }
        let samples = ProcessMath.samples(
            previous: [1: reading(1, cpu: .zero), 2: reading(2, cpu: .zero)],
            current: [reading(1, cpu: .milliseconds(10)), reading(2, cpu: .milliseconds(10))],
            identities: [:], previousGPU: [:], currentGPU: [:], elapsed: .seconds(1),
            now: born.addingTimeInterval(100), coreCount: 4, gpuPercents: [1: 40]
        )
        #expect(samples[0].gpuPercent == 40)
        #expect(samples[1].gpuPercent == 0)
    }
}
