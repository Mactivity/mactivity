import Core
import Foundation
@testable import Sampling
import Testing

struct ProcessNetworkFixture: Decodable {
    struct Process: Decodable {
        let pid: Int32
        let name: String
        let uid: UInt32
        /// Seconds since 1970.
        let startTime: Double
    }

    struct Counter: Decodable {
        let startTime: Double?
        let rx: UInt64
        let tx: UInt64
    }

    let elapsedSeconds: Double
    let visibleUID: UInt32
    let processes: [Process]
    let previous: [String: Counter]
    let current: [String: Counter]
    let expected: [String: ProcessNetworkMath.Rate]

    var readings: [ProcessReading] {
        processes.map { process in
            ProcessReading(
                pid: process.pid, parentPID: 1, uid: process.uid, name: process.name, executablePath: nil,
                startTime: Date(timeIntervalSince1970: process.startTime), cpuTime: .zero, footprintBytes: 0,
                diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: true
            )
        }
    }

    var previousCounters: [Int32: ProcessNetworkMath.Counter] {
        Dictionary(uniqueKeysWithValues: previous.compactMap { key, counter in
            Int32(key).map {
                ($0, .init(startTime: Date(timeIntervalSince1970: counter.startTime ?? 0), rx: counter.rx, tx: counter.tx))
            }
        })
    }

    var currentBytes: [Int32: (rx: UInt64, tx: UInt64)] {
        Dictionary(uniqueKeysWithValues: current.compactMap { key, counter in Int32(key).map { ($0, (counter.rx, counter.tx)) } })
    }
}

@Suite("Process network math")
struct ProcessNetworkMathTests {
    let fixture: ProcessNetworkFixture

    init() throws {
        fixture = try Fixtures.load("network-per-pid-rates.json")
    }

    func rates() -> (rates: [Int32: ProcessNetworkMath.Rate], counters: [Int32: ProcessNetworkMath.Counter]) {
        ProcessNetworkMath.rates(
            previous: fixture.previousCounters,
            current: fixture.currentBytes,
            processes: fixture.readings,
            visibleUID: fixture.visibleUID,
            elapsedSeconds: fixture.elapsedSeconds
        )
    }

    @Test("Deltas over elapsed; closed bytes, no sockets, going backwards, PID reuse and first sight as the fixture says")
    func fixtureRates() {
        let result = rates()
        #expect(Set(result.rates.keys.map(String.init)) == Set(fixture.expected.keys))
        for (pid, expected) in fixture.expected {
            guard let key = Int32(pid), let rate = result.rates[key] else {
                Issue.record("No rate for \(pid)")
                continue
            }
            #expect(abs(rate.inBPS - expected.inBPS) < 1e-6, "pid \(pid) in")
            #expect(abs(rate.outBPS - expected.outBPS) < 1e-6, "pid \(pid) out")
        }
    }

    @Test("Another user's process gets no rate and no counter")
    func otherUsers() {
        let result = rates()
        #expect(result.rates[484] == nil)
        #expect(result.counters[484] == nil)
    }

    @Test("The next baseline is this pass's counts, with the current start time")
    func counters() {
        let counters = rates().counters
        #expect(counters[666] == .init(startTime: Date(timeIntervalSince1970: 1_789_990_000), rx: 1000, tx: 14_768_641))
        #expect(counters[659]?.startTime == Date(timeIntervalSince1970: 1_790_005_000))
        #expect(counters[714] == .init(startTime: Date(timeIntervalSince1970: 1_789_990_000), rx: 0, tx: 0))
    }

    @Test("A process that started after the previous query gets all its bytes; an older one first seen doesn't (D-142)")
    func youngProcess() {
        let lastQuery = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ pid: Int32, started: Date) -> ProcessReading {
            ProcessReading(
                pid: pid, parentPID: 1, uid: 501, name: "curl", executablePath: nil, startTime: started, cpuTime: .zero,
                footprintBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: true, wakeups: 0
            )
        }
        let result = ProcessNetworkMath.rates(
            previous: [:],
            current: [10: (rx: 2_000_000_000, tx: 0), 11: (rx: 5_000_000, tx: 0)],
            processes: [reading(10, started: lastQuery.addingTimeInterval(5)), reading(11, started: lastQuery.addingTimeInterval(-600))],
            visibleUID: 501, elapsedSeconds: 60, previousQueryAt: lastQuery
        )
        #expect(abs((result.rates[10]?.inBPS ?? 0) - 2_000_000_000 / 60) < 1)
        #expect(result.rates[11]?.inBPS == 0)
    }

    @Test("With no elapsed time (the first pass), every visible process is 0 B/s")
    func firstPass() {
        let result = ProcessNetworkMath.rates(
            previous: [:], current: fixture.currentBytes, processes: fixture.readings, visibleUID: nil, elapsedSeconds: 0
        )
        #expect(result.rates.count == fixture.processes.count)
        #expect(result.rates.values.allSatisfy { $0.inBPS == 0 && $0.outBPS == 0 })
    }

    @Test("Applying rates fills net figures and leaves processes without a rate at nil")
    func applying() {
        let samples = [34963, 484].map { pid in
            ProcessSample(
                pid: Int32(pid), app: "app", name: "p", cpuPercent: 1, footprintBytes: 2, diskReadBPS: 3,
                diskWriteBPS: 4, energyMW: 5, netInBPS: nil, netOutBPS: nil, gpuPercent: 6, energyImpact: 7
            )
        }
        let applied = ProcessNetworkMath.applying(rates().rates, to: samples)
        // Every other field survives, Energy Impact included (it was dropped once, D-074).
        #expect(applied[0].energyImpact == 7)
        #expect(applied[0].cpuPercent == 1 && applied[0].footprintBytes == 2 && applied[0].name == "p")
        #expect(applied[0].netInBPS == 500_000)
        #expect(applied[0].netOutBPS == 100_000)
        #expect(applied[0].gpuPercent == 6)
        #expect(applied[0].energyMW == 5)
        #expect(applied[1] == samples[1])
    }
}
