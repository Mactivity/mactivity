import Core
import Foundation
import os

/// Process readings from the privileged helper when it's installed and reachable, from the
/// app's own `ProcessSampler` otherwise (spec 6.9). A failed or slow helper call falls back
/// for that tick, so the helper can never stall sampling.
public actor HelperProcessSource: ProcessSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private static let log = Logger(subsystem: "app.mactivity.sampling", category: "helper")

    private let local: ProcessSampler
    private let requirement: String?
    private var connection: NSXPCConnection?
    private var isEnabled = false
    private let decoder = JSONDecoder()

    /// - Parameter teamID: the app's own team; the helper must be signed by the same one.
    public init(local: ProcessSampler = ProcessSampler(), teamID: String?) {
        self.local = local
        requirement = HelperIdentity.requirement(identifier: HelperIdentity.helperBundleID, teamID: teamID)
    }

    /// Turned on when Settings → Helper is on and the daemon is registered.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && requirement != nil
        if !isEnabled {
            connection?.invalidate()
            connection = nil
        }
    }

    public func sample() async throws -> [ProcessReading] {
        try await sample(skippingUsageFor: [])
    }

    public func sample(skippingUsageFor pids: Set<Int32>) async throws -> [ProcessReading] {
        if isEnabled, let readings = await helperReadings() {
            return readings
        }
        return try await local.sample(skippingUsageFor: pids)
    }

    private func helperReadings() async -> [ProcessReading]? {
        guard let connection = connectionIfPossible() else {
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // An unreachable helper fails through the error handler right away; a stuck one gets
            // a second, then the tick goes on without it.
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Self.log.notice("Helper unreachable: \(String(describing: error))")
                once.resume(nil)
            } as? MactivityHelperXPC
            guard let proxy else {
                once.resume(nil)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                once.resume(nil)
            }
            proxy.sample { once.resume($0) }
        }
        guard let data else {
            return nil
        }
        do {
            return try decoder.decode([ProcessReading].self, from: data)
        } catch {
            Self.log.error("Helper sent unreadable data: \(String(describing: error))")
            return nil
        }
    }

    private func connectionIfPossible() -> NSXPCConnection? {
        guard let requirement else {
            return nil
        }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MactivityHelperXPC.self)
            connection.setCodeSigningRequirement(requirement)
            connection.invalidationHandler = { [weak self] in
                Task { await self?.dropConnection() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection
    }

    private func dropConnection() {
        connection = nil
    }
}

/// Resumes a continuation exactly once, from whichever of the reply or the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
