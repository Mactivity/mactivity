import Core
import Foundation

/// Turns two ticks of cumulative process readings into per-interval rates (spec 6.1). Pure.
public enum ProcessMath {
    /// The shortest span a new process's rates are measured over, in seconds.
    static let minimumRateWindow: Double = 1

    /// - Parameters:
    ///   - previous: last tick's readings by PID.
    ///   - current: this tick's readings.
    ///   - identities: the app each current PID belongs to. Missing PIDs go to "Other".
    ///   - previousGPU, currentGPU: cumulative GPU nanoseconds per PID (empty if unavailable).
    ///   - elapsed: wall time between the two ticks.
    ///   - now: when `current` was read; used to age processes that started during the interval.
    ///   - coreCount: logical cores; CPU % is of the whole machine, like the system figure.
    ///   - gpuPercents: per-process GPU % already worked out (`gpuPercents(…)`), used instead of
    ///     `previousGPU` / `currentGPU` when given: the sampler walks the GPU's clients less often
    ///     than it reads processes (D-086). Processes missing from it read 0.
    public static func samples(
        previous: [Int32: ProcessReading],
        current: [ProcessReading],
        identities: [Int32: AppIdentity],
        previousGPU: [Int32: UInt64],
        currentGPU: [Int32: UInt64],
        elapsed: Duration,
        now: Date,
        coreCount: Int,
        gpuPercents: [Int32: Double]? = nil,
        energy: EnergyCoefficients = EnergyCoefficientsLoader.current
    ) -> [ProcessSample] {
        // With no elapsed time (the first pass) every process is still listed, at zero rates.
        let elapsedSeconds = elapsed.seconds
        let cores = Double(max(1, coreCount))
        let gpuAvailable = gpuPercents != nil || !currentGPU.isEmpty
        return current.map { reading in
            // Same process only if the start time matches; counters are only comparable when both
            // readings had them (a skipped or refused reading carries zeros).
            let before = previous[reading.pid].flatMap {
                $0.startTime == reading.startTime && $0.isComplete == reading.isComplete ? $0 : nil
            }
            // A process we haven't seen: rates since it started if that was during this interval,
            // otherwise zero until the next tick (its counters include time before we looked).
            // A very young process is rated over at least `minimumRateWindow`: its counters move in
            // steps (wakeups, disk blocks), and a step over a millisecond read as an Energy Impact
            // in the tens of thousands (Xcode's build tools, 2026-09-27).
            let age = now.timeIntervalSince(reading.startTime)
            let window: Double? = elapsedSeconds <= 0 ? nil
                : before != nil ? elapsedSeconds
                : (age > 0 && age <= elapsedSeconds ? max(age, min(minimumRateWindow, elapsedSeconds)) : nil)
            let app = identities[reading.pid] ?? .other(executableName: reading.name)

            func rate(_ now: UInt64, _ then: UInt64?) -> Double {
                guard let window else {
                    return 0
                }
                let base = then ?? 0
                return now >= base ? Double(now - base) / window : 0
            }

            let cpuNow = UInt64(max(0, nanoseconds(reading.cpuTime)))
            let cpuThen = before.map { UInt64(max(0, nanoseconds($0.cpuTime))) }
            let cpuPercent = min(100, rate(cpuNow, cpuThen) / 1e9 / cores * 100)

            // GPU time per PID is a sum over the accelerator's user clients; if a client went away
            // the sum can drop, which reads as zero for that tick.
            var gpuPercent: Double?
            if let gpuPercents {
                gpuPercent = gpuPercents[reading.pid] ?? 0
            } else if gpuAvailable {
                gpuPercent = 0
                if before != nil, elapsedSeconds > 0, let then = previousGPU[reading.pid], let gpuNow = currentGPU[reading.pid],
                   gpuNow >= then {
                    gpuPercent = min(100, Double(gpuNow - then) / elapsedSeconds / 1e9 * 100)
                }
            }

            // Energy Impact (expansion E13): macOS's own weights over this interval's deltas.
            var energyImpact: Double?
            if reading.isComplete, let window {
                let gpuSeconds = (gpuPercent ?? 0) / 100 * window
                energyImpact = energy.impact(
                    cpuSeconds: rate(cpuNow, cpuThen) / 1e9 * window,
                    wakeups: rate(reading.wakeups, before?.wakeups) * window,
                    bytesRead: rate(reading.diskReadBytes, before?.diskReadBytes) * window,
                    bytesWritten: rate(reading.diskWriteBytes, before?.diskWriteBytes) * window,
                    gpuSeconds: gpuSeconds,
                    seconds: window
                )
            }

            return ProcessSample(
                pid: reading.pid,
                app: app.id,
                name: reading.name,
                cpuPercent: cpuPercent,
                footprintBytes: reading.footprintBytes,
                diskReadBPS: rate(reading.diskReadBytes, before?.diskReadBytes),
                diskWriteBPS: rate(reading.diskWriteBytes, before?.diskWriteBytes),
                // nJ/s = nW; ÷ 1e6 → mW.
                energyMW: reading.isComplete ? rate(reading.energyNJ, before?.energyNJ) / 1e6 : nil,
                netInBPS: nil,
                netOutBPS: nil,
                gpuPercent: gpuPercent,
                energyImpact: energyImpact
            )
        }
    }

    /// Per-process GPU % between two walks of the GPU's clients, `elapsed` apart: the process's
    /// GPU nanoseconds over that span. 0 for a process not at the earlier walk, or a different
    /// process with the same PID (start times differ), or when the sum dropped (a client went away).
    public static func gpuPercents(
        previous: [Int32: UInt64],
        current: [Int32: UInt64],
        previousStarts: [Int32: Date],
        currentStarts: [Int32: Date],
        elapsed: Duration
    ) -> [Int32: Double] {
        let elapsedSeconds = elapsed.seconds
        var result: [Int32: Double] = [:]
        result.reserveCapacity(current.count)
        for (pid, now) in current {
            var percent = 0.0
            if elapsedSeconds > 0, let then = previous[pid], now >= then,
               let start = currentStarts[pid], previousStarts[pid] == start {
                percent = min(100, Double(now - then) / elapsedSeconds / 1e9 * 100)
            }
            result[pid] = percent
        }
        return result
    }

    static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}
