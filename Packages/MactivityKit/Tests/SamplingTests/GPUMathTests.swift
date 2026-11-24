import Core
import Foundation
@testable import Sampling
import Testing

@Suite("GPU math")
struct GPUMathTests {
    let fixture: [String: Any]

    init() throws {
        fixture = try JSONFixture.object("gpu-accelerator-m5pro.json")
    }

    @Test("Utilization, memory, and name come from PerformanceStatistics and model")
    func stats() throws {
        let statistics = try #require(fixture["performanceStatistics"] as? [String: Any])
        let name = try #require(fixture["model"] as? String)
        let stats = try #require(GPUMath.stats(performanceStatistics: statistics, name: name))
        #expect(stats.name == "Apple M5 Pro")
        #expect(stats.utilizationPercent == 57)
        #expect(stats.memoryInUseBytes == 23_396_352)
    }

    @Test("Statistics without Device Utilization % give nil; utilization is clamped")
    func missingUtilization() throws {
        #expect(GPUMath.stats(performanceStatistics: ["In use system memory": 5], name: "GPU") == nil)
        let over = try #require(GPUMath.stats(performanceStatistics: ["Device Utilization %": 130], name: "GPU"))
        #expect(over.utilizationPercent == 100)
        #expect(over.memoryInUseBytes == nil)
    }

    @Test(
        "Creator strings parse to PID and name",
        arguments: [
            ("pid 410, WindowServer", Creator(pid: 410, name: "WindowServer")),
            ("pid 926, 1Password Helper", Creator(pid: 926, name: "1Password Helper")),
            ("pid 86549, UserNotification", Creator(pid: 86549, name: "UserNotification")),
            ("pid 7, a, b", Creator(pid: 7, name: "a, b")),
            ("pid 0, kernel_task", Creator(pid: 0, name: "kernel_task")),
        ]
    )
    func creator(string: String, expected: Creator) throws {
        let parsed = try #require(GPUMath.parseCreator(string))
        #expect(parsed.pid == expected.pid)
        #expect(parsed.name == expected.name)
    }

    struct Creator: Sendable, CustomTestStringConvertible {
        let pid: Int32
        let name: String

        var testDescription: String {
            "pid \(pid) \"\(name)\""
        }
    }

    @Test("Malformed creator strings give nil", arguments: ["", "pid ", "pid x, Foo", "process 12, Foo", "pid -3, Foo"])
    func malformedCreator(string: String) {
        #expect(GPUMath.parseCreator(string) == nil)
    }

    @Test("AppUsage sums accumulatedGPUTime over every API entry")
    func appUsage() {
        let usage: [Any] = [
            ["API": "Metal", "accumulatedGPUTime": 15_389_780_790_541, "lastSubmittedTime": 1],
            ["API": "Metal", "accumulatedGPUTime": 578_053_375],
            ["API": "Metal"],
            "not a dictionary",
        ]
        #expect(GPUMath.accumulatedGPUTime(appUsage: usage) == 15_390_358_843_916)
        #expect(GPUMath.accumulatedGPUTime(appUsage: [Any]()) == 0)
        #expect(GPUMath.accumulatedGPUTime(appUsage: nil) == nil)
        #expect(GPUMath.accumulatedGPUTime(appUsage: "()") == nil)
    }

    @Test("Real user clients sum per PID, several clients per process included")
    func clientTimes() throws {
        let clients = try #require(fixture["clients"] as? [[String: Any]])
        let expected = try #require(fixture["expectedGPUTime"] as? [String: NSNumber])
        let times = GPUMath.clientGPUTime(clients: clients)
        #expect(times.count == expected.count)
        for (pid, time) in expected {
            #expect(times[Int32(pid) ?? -1] == time.uint64Value, "pid \(pid)")
        }
        // WindowServer holds two clients in the fixture; one has no usage.
        #expect(times[410] == 15_394_213_300_416)
    }

    @Test("Clients without a creator are skipped")
    func noCreator() {
        let clients: [[String: Any]] = [["AppUsage": [["accumulatedGPUTime": 5]]], ["IOUserClientCreator": "pid 9, x"]]
        #expect(GPUMath.clientGPUTime(clients: clients) == [9: 0])
    }
}

/// Smoke test of the IORegistry wrappers on this Mac.
@Suite(
    "GPU sampler (live)",
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct GPUSamplerTests {
    @Test("Finds the accelerator, reads utilization, and attributes GPU time to clients")
    func plausible() async throws {
        let sampler = GPUSampler()
        let stats = try #require(try await sampler.sample())
        #expect(stats.name.hasPrefix("Apple M"))
        #expect((0 ... 100).contains(stats.utilizationPercent))
        #expect(stats.memoryInUseBytes != nil)
        let times = await sampler.clientGPUTime()
        #expect(!times.isEmpty)
        // WindowServer composites every frame, so some client always has GPU time.
        #expect(times.values.contains { $0 > 0 })
    }
}
