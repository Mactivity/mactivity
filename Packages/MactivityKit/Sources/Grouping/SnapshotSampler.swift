import Core
import Darwin
import Foundation
import os
import Sampling

/// The one sampling loop (spec 6.13): every tick reads every source, attributes processes to
/// apps, turns counters into rates, and broadcasts one `Snapshot`. Nothing else polls.
public actor SnapshotSampler: SnapshotSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    public struct Sources: Sendable {
        public var cpu: any CPUSource
        public var memory: any MemorySource
        public var disk: any DiskSource
        public var network: any NetworkSource
        public var gpu: any GPUSource
        public var battery: any BatterySource
        public var processes: any ProcessSource
        public var resolver: any AppResolver
        public var sensors: (any SensorSource)?
        /// Per-process network bytes (spec 6.5). Nil leaves per-app network rates nil.
        public var processNetwork: (any ProcessNetworkSource)?
        public var thermal: @Sendable () -> ThermalPressure

        public init(
            cpu: any CPUSource, memory: any MemorySource, disk: any DiskSource, network: any NetworkSource,
            gpu: any GPUSource, battery: any BatterySource, processes: any ProcessSource, resolver: any AppResolver,
            sensors: (any SensorSource)? = nil, processNetwork: (any ProcessNetworkSource)? = nil,
            thermal: @escaping @Sendable () -> ThermalPressure
        ) {
            self.sensors = sensors
            self.processNetwork = processNetwork
            self.cpu = cpu
            self.memory = memory
            self.disk = disk
            self.network = network
            self.gpu = gpu
            self.battery = battery
            self.processes = processes
            self.resolver = resolver
            self.thermal = thermal
        }
    }

    private static let log = Logger(subsystem: "app.mactivity.grouping", category: "sampler")

    private let sources: Sources
    /// Suspending, not continuous: rates divide counters by the time between ticks, and process
    /// CPU time, disk and network counters don't move while the Mac sleeps. A continuous clock
    /// spread the first tick after a wake over the whole sleep, so every app read ~0% and the
    /// macOS row took all the CPU (D-142).
    private let clock = SuspendingClock()
    private var cadence: SamplingCadence = .idle
    private var latest: Snapshot?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    /// Identifies the current sleep so a stale timer can't end the next one early.
    private var sleepGeneration = 0

    private var previousReadings: [Int32: ProcessReading] = [:]
    /// The GPU's clients at the last walk: GPU nanoseconds and start time per PID, and the
    /// per-process percentages worked out then. Nil percentages: not walked (idle) or no clients.
    private var previousGPU: [Int32: UInt64] = [:]
    private var previousGPUStarts: [Int32: Date] = [:]
    private var lastGPUWalk: SuspendingClock.Instant?
    private var lastGPUPercents: [Int32: Double]?
    private var gpuDetail = false
    /// While a window is open, per-app GPU is walked every tick only when a figure that changes
    /// every tick shows it (the menu bar window's GPU tab); otherwise every 3 s, the app lists'
    /// refresh (D-086). Each walk is ~0.6 ms of IORegistry reads (D-024).
    public static let visibleGPUInterval: Duration = .seconds(3)
    private var previousNetwork: [Int32: ProcessNetworkMath.Counter] = [:]
    private var previousNetworkQuery: SuspendingClock.Instant?
    /// The wall-clock time of that query: processes started after it get all their bytes (D-142).
    private var previousNetworkQueryDate: Date?
    private var lastNetworkRates: [Int32: ProcessNetworkMath.Rate] = [:]
    /// Per-app network is queried less often than processes are read; passes in between reuse
    /// the last rates. Each query makes NetworkStatistics build a dictionary for every open
    /// socket, the biggest idle cost on a busy Mac (D-059). Counters are cumulative and closed
    /// sockets' final counts are kept, so no bytes are lost; history and the heavy-network alert
    /// use minute averages, and app lists refresh every 3 s anyway.
    public static let idleNetworkInterval: Duration = .seconds(60)
    public static let visibleNetworkInterval: Duration = .seconds(3)
    /// PIDs attributed to macOS last tick. While idle their usage isn't read: the macOS row
    /// takes the system remainder, so the totals stay right (D-022).
    private var systemPIDs: Set<Int32> = []
    private var previousTick: SuspendingClock.Instant?
    /// While idle, processes and system figures are read every 10 s (D-029, D-051). Between process passes the last per-app
    /// figures are reused and the macOS remainder is recomputed against fresh system totals.
    public static let idleProcessInterval: Duration = .seconds(10)
    private var previousProcessPass: SuspendingClock.Instant?
    private var lastSamples: [ProcessSample] = []
    private var lastAttributed: [AppAggregate] = []
    private var lastUnreadable = 0
    private var lastProcessCount = 0
    /// Sensors: every tick while visible; every 15 s while idle if the menu bar wants them;
    /// otherwise every 60 s, so temperature history (E8) has a reading every minute. An SMC pass
    /// is ~4 ms, so the 60 s floor costs ~0.007% of a core.
    public static let idleSensorInterval: Duration = .seconds(15)
    public static let historySensorInterval: Duration = .seconds(60)
    private var sensorDemand = false
    private var systemDetail = false
    private var visibleInterval = SamplingCadence.visible.interval
    private var lastSensorRead: SuspendingClock.Instant?
    private var lastSensors: SensorStats?

    /// How long the last tick took, for the performance budget.
    public private(set) var lastTickDuration: Duration = .zero

    /// How often per-app network is queried: (visible, idle). Tests pass zero to query every pass.
    private let networkIntervals: (visible: Duration, idle: Duration)

    public init(
        sources: Sources,
        networkIntervals: (visible: Duration, idle: Duration) = (visibleNetworkInterval, idleNetworkInterval)
    ) {
        self.sources = sources
        self.networkIntervals = networkIntervals
    }

    public func snapshots() async -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        continuations[id] = continuation
        if let latest {
            continuation.yield(latest)
        }
        startIfNeeded()
        return stream
    }

    public func setCadence(_ cadence: SamplingCadence) async {
        let wasIdle = self.cadence == .idle
        self.cadence = cadence
        // Going visible ticks right away so a window never opens on a five-second-old figure.
        if wasIdle, cadence == .visible {
            wakeUp(generation: sleepGeneration)
        }
    }

    public func setSensorDemand(_ wanted: Bool) async {
        sensorDemand = wanted
    }

    public func setSystemDetail(_ wanted: Bool) async {
        let was = systemDetail
        systemDetail = wanted
        // Expanding the macOS row ticks right away: until a pass reads them, its processes
        // aren't in the snapshot at all (D-086).
        if wanted, !was, cadence == .visible {
            wakeUp(generation: sleepGeneration)
        }
    }

    public func setGPUDetail(_ wanted: Bool) async {
        gpuDetail = wanted
    }

    public func setVisibleInterval(_ interval: Duration) async {
        visibleInterval = max(.seconds(1), interval)
    }

    /// One tick, outside the loop. Tests and the first sample use this.
    public func tick() async -> Snapshot {
        let started = clock.now
        let now = Date()
        let elapsed = previousTick.map { started - $0 } ?? .zero
        previousTick = started

        // Sequential on purpose: every source takes well under a millisecond, and fanning out
        // with `async let` woke six pool threads per tick, which cost more than the work itself.
        let cpu = await (try? sources.cpu.sample())
            ?? CPUStats.aggregate(perCore: [], topology: CPUTopology(levels: []), loadAverage: .zero)
        let memory = await (try? sources.memory.sample()) ?? Self.emptyMemory
        let disk = await (try? sources.disk.sample()) ?? DiskStats(volumes: [], readBPS: 0, writeBPS: 0)
        let network = await (try? sources.network.sample()) ?? NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil)
        let gpu = try? await sources.gpu.sample()
        let battery = try? await sources.battery.sample()

        let system = await SystemSample(
            cpu: cpu,
            memory: memory,
            disk: disk,
            network: network,
            gpu: gpu,
            battery: battery,
            sensors: readSensorsIfDue(started),
            thermal: sources.thermal(),
            uptime: Self.uptime(now: now)
        )

        // Tolerance: the idle loop sleeps 5 s, so two ticks are a hair under 10 s apart.
        let processDue = cadence == .visible
            || previousProcessPass.map { started - $0 >= Self.idleProcessInterval - .milliseconds(500) } ?? true
        if processDue {
            await readProcesses(started: started, now: now, coreCount: cpu.perCorePercent.count)
        }
        let apps = AppAggregation.addingSystemRemainder(
            to: lastAttributed,
            systemCPUPercent: cpu.totalPercent,
            systemMemoryBytes: memory.usedBytes,
            unreadableProcessCount: lastUnreadable
        )
        let samples = lastSamples
        let snapshot = Snapshot(
            at: now, interval: elapsed, system: system, apps: apps, processes: samples,
            processCount: lastProcessCount, systemPIDs: systemPIDs
        )
        latest = snapshot
        lastTickDuration = clock.now - started
        if lastTickDuration > .milliseconds(50) {
            Self.log.notice("Slow tick: \(self.lastTickDuration.formatted(.units(allowed: [.milliseconds])))")
        }
        return snapshot
    }

    private func readSensorsIfDue(_ started: SuspendingClock.Instant) async -> SensorStats? {
        guard let source = sources.sensors else {
            return nil
        }
        let interval = sensorDemand ? Self.idleSensorInterval : Self.historySensorInterval
        let due = cadence == .visible
            || lastSensorRead.map { started - $0 >= interval - .milliseconds(500) } ?? true
        if due {
            lastSensorRead = started
            lastSensors = try? await source.sample()
        }
        return lastSensors
    }

    /// One pass over the process table: readings → rates → per-app sums.
    private func readProcesses(started: SuspendingClock.Instant, now: Date, coreCount: Int) async {
        let elapsed = previousProcessPass.map { started - $0 } ?? .zero
        previousProcessPass = started
        // macOS's own processes (~90% of them) are the system remainder unless their row is
        // expanded, so their usage is read only then, idle or not (D-022, D-063).
        let detailed = cadence == .visible && systemDetail
        let readings = await (try? sources.processes.sample(skippingUsageFor: detailed ? [] : systemPIDs)) ?? []
        let gpuPercents = await readGPUPercents(started: started, readings: readings)
        let identities = await sources.resolver.resolve(readings)
        let networkRates = await readNetworkRates(readings: readings)
        let partition = ProcessPartition(
            readings: readings, identities: identities, detailed: detailed,
            gpuPIDs: gpuPercents ?? [:], networkPIDs: networkRates ?? [:]
        )
        var samples = ProcessMath.samples(
            previous: previousReadings,
            current: partition.kept,
            identities: identities,
            previousGPU: [:],
            currentGPU: [:],
            elapsed: elapsed,
            now: now,
            coreCount: coreCount,
            gpuPercents: gpuPercents
        )
        if let networkRates {
            samples = ProcessNetworkMath.applying(networkRates, to: samples)
        }
        // Omitted processes aren't needed here: their next reading has no counters either.
        previousReadings = Dictionary(partition.kept.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        systemPIDs = partition.systemPIDs
        lastSamples = samples
        lastAttributed = AppAggregation.aggregate(
            processes: samples,
            identities: partition.identitiesByID(identities),
            omittedSystemProcesses: partition.omittedSystemCount,
            gpuAvailable: gpuPercents != nil
        )
        lastUnreadable = partition.unreadableCount
        lastProcessCount = readings.count
    }

    private func startIfNeeded() {
        guard loop == nil else {
            return
        }
        loop = Task { [weak self] in
            // Prime the counters, then publish the first real tick after a second.
            _ = await self?.tick()
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await broadcast(tick())
                await sleep()
            }
        }
    }

    /// Sleeps for the cadence interval, or until `setCadence(.visible)` wakes it early.
    private func sleep() async {
        let interval = Self.sleepInterval(
            cadence: cadence, visible: visibleInterval, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        // Slack lets macOS batch this wake-up with others instead of waking the Mac on the dot:
        // rates use the real elapsed time, so a late tick costs nothing in accuracy (D-060).
        let tolerance = Self.sleepTolerance(for: cadence)
        sleepGeneration += 1
        let generation = sleepGeneration
        await withCheckedContinuation { continuation in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: interval, tolerance: tolerance)
                await self?.wakeUp(generation: generation)
            }
        }
    }

    /// Pure: the visible interval (1 s by default, D-065) or the idle one (10 s), doubled while
    /// Low Power Mode is on, so Mactivity does its part when the Mac is asked to save energy (D-071).
    static func sleepInterval(cadence: SamplingCadence, visible: Duration, lowPower: Bool) -> Duration {
        let base = cadence == .visible ? visible : cadence.interval
        return lowPower ? base * 2 : base
    }

    /// 20% of the idle interval (up to 2 s late at 10 s); a tenth of a second while a window
    /// shows figures ticking every second.
    static func sleepTolerance(for cadence: SamplingCadence) -> Duration {
        cadence == .visible ? .milliseconds(100) : cadence.interval / 5
    }

    private func wakeUp(generation: Int) {
        guard generation == sleepGeneration else {
            return
        }
        wake?.resume()
        wake = nil
    }

    private func broadcast(_ snapshot: Snapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
        if continuations.isEmpty {
            loop?.cancel()
            loop = nil
            wakeUp(generation: sleepGeneration)
        }
    }

    private static let emptyMemory = MemoryStats(
        totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
        cachedFilesBytes: 0, swapUsedBytes: 0, pressure: .normal, availableLevel: 100
    )

    /// Wall-clock uptime including sleep, from `kern.boottime`.
    private static func uptime(now: Date) -> Duration {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else {
            return .seconds(Int(ProcessInfo.processInfo.systemUptime))
        }
        let booted = Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        return .seconds(max(0, now.timeIntervalSince(booted)))
    }
}

/// Per-app GPU and network, kept apart from the loop (same file: they use its private state).
extension SnapshotSampler {
    /// Per-process GPU % while a window is open: walked when due (`gpuWalkDue`), otherwise the
    /// last walk's. Nil while idle, when per-app GPU isn't read at all, and when the GPU has no
    /// readable clients.
    private func readGPUPercents(started: SuspendingClock.Instant, readings: [ProcessReading]) async -> [Int32: Double]? {
        guard cadence == .visible else {
            previousGPU = [:]
            previousGPUStarts = [:]
            lastGPUWalk = nil
            lastGPUPercents = nil
            return nil
        }
        guard Self.gpuWalkDue(detail: gpuDetail, lastWalk: lastGPUWalk, now: started) else {
            return lastGPUPercents
        }
        let times = await sources.gpu.clientGPUTime()
        var starts: [Int32: Date] = [:]
        starts.reserveCapacity(times.count)
        if !times.isEmpty {
            for reading in readings where times[reading.pid] != nil {
                starts[reading.pid] = reading.startTime
            }
        }
        let percents = ProcessMath.gpuPercents(
            previous: previousGPU, current: times, previousStarts: previousGPUStarts, currentStarts: starts,
            elapsed: lastGPUWalk.map { started - $0 } ?? .zero
        )
        previousGPU = times
        previousGPUStarts = starts
        lastGPUWalk = started
        lastGPUPercents = times.isEmpty ? nil : percents
        return lastGPUPercents
    }

    /// Pure: every pass while a per-tick figure shows per-app GPU, otherwise every
    /// `visibleGPUInterval`; the first visible pass always walks.
    static func gpuWalkDue(detail: Bool, lastWalk: SuspendingClock.Instant?, now: SuspendingClock.Instant) -> Bool {
        guard !detail, let lastWalk else {
            return true
        }
        return now - lastWalk >= visibleGPUInterval - .milliseconds(500)
    }

    /// Per-process network rates from the cumulative counters: queried when due, otherwise the
    /// last ones. Nil when there's no source or it's unavailable.
    private func readNetworkRates(readings: [ProcessReading]) async -> [Int32: ProcessNetworkMath.Rate]? {
        guard Self.networkQueryDue(
            cadence: cadence, lastQuery: previousNetworkQuery, now: clock.now, intervals: networkIntervals
        ) else {
            return lastNetworkRates
        }
        guard let source = sources.processNetwork, let bytes = await source.cumulativeBytes() else {
            previousNetwork = [:]
            previousNetworkQuery = nil
            previousNetworkQueryDate = nil
            lastNetworkRates = [:]
            return nil
        }
        let queried = clock.now
        let elapsed = previousNetworkQuery.map { queried - $0 } ?? .zero
        let queriedAt = Date()
        defer { previousNetworkQueryDate = queriedAt }
        previousNetworkQuery = queried
        let result = ProcessNetworkMath.rates(
            previous: previousNetwork,
            current: bytes,
            processes: readings,
            visibleUID: source.visibleUID,
            elapsedSeconds: elapsed.seconds,
            previousQueryAt: previousNetworkQueryDate
        )
        previousNetwork = result.counters
        lastNetworkRates = result.rates
        return result.rates
    }

    /// Pure: every `visibleNetworkInterval` while a window is open, every `idleNetworkInterval`
    /// otherwise; the first pass always queries.
    static func networkQueryDue(
        cadence: SamplingCadence,
        lastQuery: SuspendingClock.Instant?,
        now: SuspendingClock.Instant,
        intervals: (visible: Duration, idle: Duration) = (visibleNetworkInterval, idleNetworkInterval)
    ) -> Bool {
        guard let lastQuery else {
            return true
        }
        let interval = cadence == .visible ? intervals.visible : intervals.idle
        return now - lastQuery >= interval - .milliseconds(500)
    }
}
