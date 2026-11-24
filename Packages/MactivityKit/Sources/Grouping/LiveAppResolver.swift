import AppKit
import Core
import Foundation
import os
import PrivateAPIs

/// Resolves live processes to apps, caching each answer for the life of the process.
public actor LiveAppResolver: AppResolver {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    /// The executable path too: after `exec` the same PID and start time are another program,
    /// which may belong to another app (D-142).
    private struct ProcessKey: Hashable {
        let pid: Int32
        let start: Date
        let path: String?
    }

    private struct CachedBundle {
        let modified: Date?
        let info: BundleInfo?
        let checkedAt: ContinuousClock.Instant
    }

    /// A cached bundle is trusted this long before its modification date is checked again: the
    /// check is a `stat` per new process, which showed up on busy Macs with lots of short-lived
    /// processes (D-059). An app update is picked up within this window.
    static let bundleRecheckInterval: Duration = .seconds(300)

    private var identities: [ProcessKey: AppIdentity] = [:]
    private var bundles: [String: CachedBundle] = [:]

    public init() {}

    public func resolve(_ processes: [ProcessReading]) async -> [Int32: AppIdentity] {
        var result: [Int32: AppIdentity] = [:]
        var unresolved: [ProcessReading] = []
        for process in processes {
            if let cached = identities[ProcessKey(pid: process.pid, start: process.startTime, path: process.executablePath)] {
                result[process.pid] = cached
            } else {
                unresolved.append(process)
            }
        }
        guard !unresolved.isEmpty else {
            return result
        }

        let running = await Self.runningApps()
        var responsible: [Int32: Int32] = [:]
        for process in unresolved {
            responsible[process.pid] = ResponsiblePID.lookup(process.pid)
        }
        let all = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = AppResolution.resolve(
            unresolved, all: all, responsible: responsible, runningApps: running, bundleAt: { self.bundle(at: $0) }
        )
        for process in unresolved {
            let identity = resolved[process.pid] ?? .other(executableName: process.name)
            identities[ProcessKey(pid: process.pid, start: process.startTime, path: process.executablePath)] = identity
            result[process.pid] = identity
        }
        // Drop cache entries for exited processes now and then.
        if identities.count > processes.count * 2 {
            let live = Set(processes.map { ProcessKey(pid: $0.pid, start: $0.startTime, path: $0.executablePath) })
            identities = identities.filter { live.contains($0.key) }
        }
        return result
    }

    @MainActor
    private static func runningApps() -> [Int32: RunningApp] {
        RunningAppsCache.shared.current()
    }

    /// Info.plist lookup, cached by (bundle path, modification date) (spec 6.2).
    private func bundle(at path: String) -> BundleInfo? {
        let now = ContinuousClock.now
        if let cached = bundles[path], now - cached.checkedAt < Self.bundleRecheckInterval {
            return cached.info
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = bundles[path], cached.modified == modified {
            bundles[path] = CachedBundle(modified: modified, info: cached.info, checkedAt: now)
            return cached.info
        }
        let info = Bundle(path: path).map { bundle in
            BundleInfo(
                path: path,
                bundleID: bundle.bundleIdentifier,
                name: AppResolution.bundleName(
                    displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                    bundleID: bundle.bundleIdentifier,
                    path: path
                )
            )
        }
        bundles[path] = CachedBundle(modified: modified, info: info, checkedAt: now)
        return info
    }
}

/// `NSWorkspace.runningApplications`, rebuilt only when an app launches or quits. Each
/// `NSRunningApplication` property read is a LaunchServices round trip, which cost more than
/// the rest of an idle tick put together.
@MainActor
final class RunningAppsCache {
    static let shared = RunningAppsCache()

    private var cached: [Int32: RunningApp]?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningAppsCache.shared.cached = nil }
            })
        }
    }

    func current() -> [Int32: RunningApp] {
        if let cached {
            return cached
        }
        var result: [Int32: RunningApp] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else {
                continue
            }
            let bundleURL = app.bundleURL
            result[pid] = RunningApp(
                pid: pid,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                bundlePath: bundleURL?.path,
                isRegular: app.activationPolicy == .regular
            )
        }
        cached = result
        return result
    }
}
