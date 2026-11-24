import Core
import Foundation
@testable import Sampling
import Testing

struct NetworkFixture: Decodable {
    let elapsedSeconds: Double
    let previous: [String: InterfaceCounters]
    let current: [String: InterfaceCounters]
    let expectedInBPS: Double
    let expectedOutBPS: Double
}

@Suite("Network math")
struct NetworkMathTests {
    let fixture: NetworkFixture

    init() throws {
        fixture = try Fixtures.load("network-interfaces-m5pro.json")
    }

    @Test("Only physical en* interfaces count; an unplugged interface adds nothing")
    func throughput() {
        let rates = NetworkMath.throughput(
            previous: fixture.previous, current: fixture.current, elapsedSeconds: fixture.elapsedSeconds
        )
        #expect(rates.inBPS == fixture.expectedInBPS)
        #expect(rates.outBPS == fixture.expectedOutBPS)
    }

    @Test("The first reading is 0 B/s")
    func firstReading() {
        let rates = NetworkMath.throughput(previous: nil, current: fixture.current, elapsedSeconds: 0)
        #expect(rates.inBPS == 0)
        #expect(rates.outBPS == 0)
    }

    @Test("An interface that appears between ticks doesn't spike with its since-boot total")
    func interfaceAppears() {
        var current = fixture.current
        current["en8"] = InterfaceCounters(bytesIn: 9_000_000_000, bytesOut: 1_000_000_000)
        let rates = NetworkMath.throughput(previous: fixture.previous, current: current, elapsedSeconds: fixture.elapsedSeconds)
        #expect(rates.inBPS == fixture.expectedInBPS)
        #expect(rates.outBPS == fixture.expectedOutBPS)
    }

    @Test("An interface that comes back with reset counters is 0 for that tick")
    func interfaceReset() {
        let before = ["en7": InterfaceCounters(bytesIn: 1_000_000, bytesOut: 500_000)]
        let after = ["en7": InterfaceCounters(bytesIn: 2000, bytesOut: 1000)]
        let rates = NetworkMath.throughput(previous: before, current: after, elapsedSeconds: 1)
        #expect(rates.inBPS == 0)
        #expect(rates.outBPS == 0)
    }

    @Test(
        "Interface filter",
        arguments: [
            ("en0", true), ("en1", true), ("en12", true),
            ("lo0", false), ("utun3", false), ("awdl0", false), ("llw0", false), ("bridge0", false),
            ("ap1", false), ("anpi0", false), ("gif0", false), ("stf0", false), ("nan0", false), ("pdp_ip0", false),
        ]
    )
    func filter(name: String, counted: Bool) {
        #expect(NetworkMath.isCounted(name) == counted)
    }
}

/// Smoke test of the sysctl and SystemConfiguration wrappers on this Mac.
@Suite("Network sampler (live)")
struct NetworkSamplerTests {
    @Test("Reads counters, a primary interface, and non-negative rates")
    func plausible() async throws {
        let sampler = NetworkSampler()
        let first = try await sampler.sample()
        #expect(first.inBPS == 0)
        #expect(first.outBPS == 0)
        try await Task.sleep(for: .milliseconds(200))
        let stats = try await sampler.sample()
        #expect(stats.inBPS >= 0)
        #expect(stats.outBPS >= 0)
        // Far above any link this Mac has (10 GbE is 1.25 GB/s): deltas, not since-boot totals.
        #expect(stats.inBPS < 5e9)
        #expect(stats.outBPS < 5e9)
        // Nil only when offline. When online, the primary interface is a BSD name like "en0".
        if let primary = stats.primaryInterface {
            #expect(!primary.isEmpty)
        }
    }
}
