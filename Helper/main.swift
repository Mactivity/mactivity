import Core
import Foundation
import os
import Sampling

// Mactivity's privileged helper (spec 6.9): a LaunchDaemon that answers one read-only call,
// `sample()`, for the one signed Mactivity app, and exits once the app has been gone 10 s.

let log = Logger(subsystem: "app.mactivity.helper", category: "helper")

/// Only connections from Mactivity signed by the same team get in.
let teamID = Bundle.main.object(forInfoDictionaryKey: "MactivityTeamID") as? String
guard let clientRequirement = HelperIdentity.requirement(identifier: HelperIdentity.appBundleID, teamID: teamID) else {
    log.error("Helper built without a team ID; refusing to serve")
    exit(1)
}

final class HelperService: NSObject, MactivityHelperXPC, @unchecked Sendable {
    private let sampler = ProcessSampler()
    private let encoder = JSONEncoder()

    func sample(withReply reply: @escaping @Sendable (Data?) -> Void) {
        let sampler = sampler
        let encoder = encoder
        Task {
            let readings = await (try? sampler.sample()) ?? []
            reply(try? encoder.encode(readings))
        }
    }

    func version(withReply reply: @escaping @Sendable (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }
}

/// Counts live connections and exits 10 s after the last one closes.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = HelperService()
    private let clientRequirement: String
    private let lock = NSLock()
    private var connections = 0
    private var generation = 0

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MactivityHelperXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        lock.lock()
        connections += 1
        generation += 1
        lock.unlock()
        connection.resume()
        return true
    }

    private func connectionEnded() {
        lock.lock()
        connections -= 1
        generation += 1
        let remaining = connections
        let current = generation
        lock.unlock()
        guard remaining == 0 else {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.exitIfStillIdle(since: current)
        }
    }

    func exitIfNeverUsed() {
        lock.lock()
        let unused = connections == 0 && generation == 0
        lock.unlock()
        if unused {
            exit(0)
        }
    }

    private func exitIfStillIdle(since generation: Int) {
        lock.lock()
        let idle = connections == 0 && self.generation == generation
        lock.unlock()
        if idle {
            Logger(subsystem: "app.mactivity.helper", category: "helper").info("Mactivity has been gone 10 s; exiting")
            exit(0)
        }
    }
}

let delegate = ListenerDelegate(clientRequirement: clientRequirement)
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
// launchd started us for a connection; if none arrives, don't linger.
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    delegate.exitIfNeverUsed()
}

dispatchMain()
