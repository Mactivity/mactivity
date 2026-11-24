import Core
import Foundation
import Sampling

public extension SnapshotSampler {
    /// One snapshot with the app's real pipeline, for the `mactivity` command and Shortcuts when
    /// no pipeline is running: two ticks `window` apart, so every rate covers that span. Reads
    /// processes locally (no helper), like the app with the helper off. Per-app network comes
    /// from the same NetworkStatistics source as the app's (D-047).
    static func oneShot(window: Duration = .seconds(1)) async -> Snapshot {
        let processNetwork = ProcessNetworkSampler()
        // The sockets already open get their process only from a first full query. Asking once
        // now means both ticks see every socket; otherwise one described between the ticks would
        // count its whole history as one second's traffic.
        _ = await processNetwork.cumulativeBytes()
        let sampler = SnapshotSampler(
            sources: .init(
                cpu: CPUSampler(),
                memory: MemorySampler(),
                disk: DiskSampler(),
                network: NetworkSampler(),
                gpu: GPUSampler(),
                battery: BatterySampler(),
                processes: ProcessSampler(),
                resolver: LiveAppResolver(),
                processNetwork: processNetwork,
                thermal: { ThermalReader.current() }
            ),
            // Query on both ticks, not every 3 s as a window does.
            networkIntervals: (.zero, .zero)
        )
        // Visible cadence: read processes on both ticks, not every 10 s. GPU detail: per-app GPU
        // walked on both ticks too; the visible cadence alone walks it every 3 s, so the second
        // tick reused the first walk's percentages, all 0 with nothing to compare (D-142).
        await sampler.setCadence(.visible)
        await sampler.setGPUDetail(true)
        _ = await sampler.tick()
        try? await Task.sleep(for: window)
        return await sampler.tick()
    }
}
