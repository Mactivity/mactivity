import Core
import Foundation
@testable import Sampling
import Testing

/// Cost of one call to each sampler on this Mac (CLAUDE.md rule 5). Serialized so the samplers
/// don't compete with each other; other suites may still run alongside, so the bound is loose and
/// the printed figure is the one to track. Run alone with `swift test --filter SamplerTimingTests`.
@Suite(
    "Sampler timing (live)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct SamplerTimingTests {
    /// Budget per call is well under 2 ms; this only catches regressions by an order of magnitude.
    static let ceilingMilliseconds = 20.0

    @Test("Memory")
    func memory() async throws {
        let sampler = MemorySampler()
        let ms = try await averageMilliseconds { _ = try await sampler.sample() }
        reportTiming("MemorySampler.sample", ms)
        #expect(ms < Self.ceilingMilliseconds)
    }

    @Test("Disk")
    func disk() async throws {
        let sampler = DiskSampler()
        let ms = try await averageMilliseconds { _ = try await sampler.sample() }
        reportTiming("DiskSampler.sample", ms)
        #expect(ms < Self.ceilingMilliseconds)
    }

    @Test("Network")
    func network() async throws {
        let sampler = NetworkSampler()
        let ms = try await averageMilliseconds { _ = try await sampler.sample() }
        reportTiming("NetworkSampler.sample", ms)
        #expect(ms < Self.ceilingMilliseconds)
    }

    @Test("GPU")
    func gpu() async throws {
        let sampler = GPUSampler()
        let ms = try await averageMilliseconds { _ = try await sampler.sample() }
        reportTiming("GPUSampler.sample", ms)
        #expect(ms < Self.ceilingMilliseconds)
        let clientMs = await averageMilliseconds { _ = await sampler.clientGPUTime() }
        reportTiming("GPUSampler.clientGPUTime", clientMs)
        #expect(clientMs < Self.ceilingMilliseconds)
    }

    @Test("Battery")
    func battery() async throws {
        let sampler = BatterySampler()
        let ms = try await averageMilliseconds { _ = try await sampler.sample() }
        reportTiming("BatterySampler.sample", ms)
        #expect(ms < Self.ceilingMilliseconds)
    }

    @Test("Thermal")
    func thermal() async {
        let ms = await averageMilliseconds { _ = ThermalReader.current() }
        reportTiming("ThermalReader.current", ms)
        #expect(ms < Self.ceilingMilliseconds)
    }
}
