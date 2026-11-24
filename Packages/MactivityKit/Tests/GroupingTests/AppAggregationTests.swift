import Core
@testable import Grouping
import Testing

@Suite("App aggregation")
struct AppAggregationTests {
    let slack = AppIdentity(id: "slack", name: "Slack", bundleID: "slack", iconKey: "", kind: .app)
    let xcode = AppIdentity(id: "xcode", name: "Xcode", bundleID: "xcode", iconKey: "", kind: .app)
    let safari = AppIdentity(id: "safari", name: "safari", bundleID: "safari", iconKey: "", kind: .app)

    func sample(
        _ pid: Int32,
        _ app: String,
        cpu: Double,
        memory: UInt64 = 100,
        energy: Double? = nil,
        netIn: Double? = nil,
        name: String = "proc"
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, app: app, name: name, cpuPercent: cpu, footprintBytes: memory, diskReadBPS: 1, diskWriteBPS: 2,
            energyMW: energy, netInBPS: netIn, netOutBPS: nil, gpuPercent: nil
        )
    }

    var identities: [AppIdentity.ID: AppIdentity] {
        [slack.id: slack, xcode.id: xcode, safari.id: safari]
    }

    var processes: [ProcessSample] {
        [
            sample(1, "slack", cpu: 5, memory: 1000, energy: 10),
            sample(2, "slack", cpu: 3, memory: 500, energy: nil),
            sample(3, "xcode", cpu: 20, memory: 4000, netIn: 50),
            sample(4, "missing", cpu: 1, name: "orphan"),
            sample(5, "missing-too", cpu: 1, name: "orphan"),
        ]
    }

    @Test("Process counts per app")
    func counts() {
        let result = AppAggregation.aggregate(processes: processes, identities: identities)
        #expect(result.first { $0.id == "slack" }?.processCount == 2)
        #expect(result.first { $0.id == "xcode" }?.processCount == 1)
    }

    @Test("Figures are sums")
    func sums() {
        let slack = AppAggregation.aggregate(processes: processes, identities: identities).first { $0.id == "slack" }
        #expect(slack?.cpuPercent == 8)
        #expect(slack?.memoryBytes == 1500)
        #expect(slack?.diskWriteBPS == 4)
    }

    @Test("Optional figures: nil only when every process is nil")
    func optionals() {
        let result = AppAggregation.aggregate(processes: processes, identities: identities)
        #expect(result.first { $0.id == "slack" }?.energyMW == 10)
        #expect(result.first { $0.id == "slack" }?.netInBPS == nil)
        #expect(result.first { $0.id == "xcode" }?.netInBPS == 50)
    }

    @Test("Unknown app IDs fold into Other by process name")
    func unknown() {
        let result = AppAggregation.aggregate(processes: processes, identities: identities)
        #expect(result.first { $0.id == "other:orphan" }?.processCount == 2)
    }

    @Test("Identities without processes produce no row")
    func noEmptyRows() {
        #expect(!AppAggregation.aggregate(processes: processes, identities: identities).contains { $0.id == "safari" })
    }

    @Test("Totals are preserved and sorted by CPU")
    func totals() {
        let result = AppAggregation.aggregate(processes: processes, identities: identities)
        #expect(abs(result.reduce(0) { $0 + $1.cpuPercent } - processes.reduce(0) { $0 + $1.cpuPercent }) < 0.0001)
        #expect(result.reduce(UInt64(0)) { $0 + $1.memoryBytes } == processes.reduce(UInt64(0)) { $0 + $1.footprintBytes })
        #expect(result.first?.id == "xcode")
    }

    @Test("The system remainder makes rows add up to the system figures")
    func remainder() {
        let apps = AppAggregation.aggregate(processes: processes, identities: identities)
        let result = AppAggregation.addingSystemRemainder(
            to: apps, systemCPUPercent: 40, systemMemoryBytes: 10000, unreadableProcessCount: 7
        )
        let system = result.first { $0.app.kind == .system }
        #expect(system?.processCount == 7)
        #expect(abs(result.reduce(0) { $0 + $1.cpuPercent } - 40) < 0.0001)
        #expect(result.reduce(UInt64(0)) { $0 + $1.memoryBytes } == 10000)
    }
}
