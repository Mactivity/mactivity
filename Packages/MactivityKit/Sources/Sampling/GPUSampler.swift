import Core
import Foundation
import IOKit

/// System-wide GPU figures from IORegistry `IOAccelerator` → "PerformanceStatistics", and
/// cumulative GPU time per client process from the accelerator's user clients (spec 6.6).
/// Public API only: IORegistry properties are readable by any process.
public actor GPUSampler: GPUSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private let matching: CFDictionary?
    /// The accelerator, retained for the sampler's lifetime (or until it stops answering).
    private var accelerator: io_service_t?
    private var name = "GPU"

    public init() {
        matching = IORegistry.matching("IOAccelerator")
    }

    deinit {
        if let accelerator {
            IOObjectRelease(accelerator)
        }
    }

    public func sample() async throws -> GPUStats? {
        guard let service = acceleratorService() else {
            return nil
        }
        guard let statistics = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] else {
            // The entry went away or never had statistics; look it up again next time.
            forgetAccelerator()
            return nil
        }
        return GPUMath.stats(performanceStatistics: statistics, name: name)
    }

    public func clientGPUTime() async -> [Int32: UInt64] {
        guard let service = acceleratorService() else {
            return [:]
        }
        var clients: [[String: Any]] = []
        IORegistry.forEachChild(of: service) { child in
            // User clients carry only a handful of small properties, so one round trip for all of
            // them beats two for the keys we want.
            if let properties = IORegistry.properties(child) {
                clients.append(properties)
            }
        }
        return GPUMath.clientGPUTime(clients: clients)
    }

    /// The first accelerator that publishes performance statistics. Apple silicon has one.
    private func acceleratorService() -> io_service_t? {
        if let accelerator {
            return accelerator
        }
        guard let matching else {
            return nil
        }
        var found: io_service_t?
        IORegistry.forEachService(matching: matching) { service in
            guard found == nil, IORegistry.property(service, "PerformanceStatistics") != nil else {
                return
            }
            // `forEachService` releases its reference when this returns; keep one of our own.
            IOObjectRetain(service)
            found = service
        }
        guard let found else {
            Log.sampling.info("no IOAccelerator with PerformanceStatistics")
            return nil
        }
        accelerator = found
        name = (IORegistry.property(found, "model") as? String) ?? "GPU"
        return found
    }

    private func forgetAccelerator() {
        if let accelerator {
            IOObjectRelease(accelerator)
        }
        accelerator = nil
    }
}
