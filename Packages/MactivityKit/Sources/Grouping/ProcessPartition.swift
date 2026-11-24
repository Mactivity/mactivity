import Core

/// Splits a pass's readings into the processes that get a `ProcessSample` and macOS's own
/// processes that are only counted (D-086). Pure.
///
/// While the macOS row is collapsed, its ~1,000 processes' usage isn't read (D-022, D-063): each
/// would become a sample of zeros, and building, rating, and summing those was most of a pass's
/// own work. Such a process contributes nothing to any figure but its count (and a 0 to the row's
/// GPU while per-app GPU is read), so it's counted instead. A macOS process still gets a sample
/// when it has anything to add: usage that was read (a process seen for the first time), any
/// counter at all, GPU time, or a network rate.
struct ProcessPartition {
    /// Readings that become samples, in the order read.
    private(set) var kept: [ProcessReading] = []
    /// Every process attributed to macOS, sampled or not; next pass skips their usage.
    private(set) var systemPIDs: Set<Int32> = []
    /// macOS processes left out of the samples, counted in the macOS row.
    private(set) var omittedSystemCount = 0
    /// Readings without counters (refused or skipped), for the macOS row when it has no processes.
    private(set) var unreadableCount = 0

    /// - Parameters:
    ///   - detailed: the macOS row is expanded in a visible window, so every process is sampled.
    ///   - gpuPIDs, networkPIDs: processes with GPU time or a network rate this pass.
    init(
        readings: [ProcessReading],
        identities: [Int32: AppIdentity],
        detailed: Bool,
        gpuPIDs: [Int32: some Any],
        networkPIDs: [Int32: some Any]
    ) {
        kept.reserveCapacity(detailed ? readings.count : readings.count / 4)
        systemPIDs.reserveCapacity(readings.count)
        for reading in readings {
            if !reading.isComplete {
                unreadableCount += 1
            }
            guard identities[reading.pid]?.kind == .system else {
                kept.append(reading)
                continue
            }
            systemPIDs.insert(reading.pid)
            if detailed || !Self.carriesNothing(reading) || gpuPIDs[reading.pid] != nil || networkPIDs[reading.pid] != nil {
                kept.append(reading)
            } else {
                omittedSystemCount += 1
            }
        }
    }

    /// A reading whose sample would be all zeros whatever came before: no usage was read, so
    /// every counter is zero (`ProcessSampler` for skipped and refused processes).
    static func carriesNothing(_ reading: ProcessReading) -> Bool {
        !reading.isComplete && reading.cpuTime == .zero && reading.footprintBytes == 0
            && reading.diskReadBytes == 0 && reading.diskWriteBytes == 0
    }

    /// The identities of the kept processes by app ID, for `AppAggregation.aggregate`.
    func identitiesByID(_ identities: [Int32: AppIdentity]) -> [AppIdentity.ID: AppIdentity] {
        var byID: [AppIdentity.ID: AppIdentity] = [:]
        for reading in kept {
            if let identity = identities[reading.pid], byID[identity.id] == nil {
                byID[identity.id] = identity
            }
        }
        return byID
    }
}
