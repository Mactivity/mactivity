import AppKit
import Core
import Darwin
import Foundation
import os

/// Stops apps and processes (spec 5.8, 6.12).
///
/// - Processes and dev servers: SIGTERM, up to 5 s to exit, then SIGKILL. Force Quit sends
///   SIGKILL straight away.
/// - Apps: `NSRunningApplication.terminate()`, the same as quitting from the Dock, so the app can
///   ask to save. It never escalates: an app that stays open is reported as a survivor. Force
///   Quit uses `forceTerminate()`, then SIGKILLs any of the app's processes still running.
///
/// Only takes a `ConfirmedTermination`, which only the UI's `ConfirmedAction` can create
/// (CLAUDE.md rule 4). Refuses launchd, the kernel, this process, and this process's group.
public actor SignalTerminator: ProcessTerminator {
    private static let log = Logger(subsystem: "app.mactivity.projects", category: "terminator")

    public static let gracePeriod: Duration = .seconds(5)

    public init() {}

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        switch request.target {
        case let .processGroup(group):
            guard group > 1, group != getpgrp() else {
                throw TerminationError.refused
            }
            let members = ProcessInspector.members(ofGroup: group)
            return await stop(members: members, mode: request.mode, signal: { killpg(group, $0) })
        case let .process(pid):
            guard pid > 1, pid != getpid() else {
                throw TerminationError.refused
            }
            return await stop(members: [pid], mode: request.mode, signal: { kill(pid, $0) })
        case let .app(id, pids):
            let safe = pids.filter { $0 > 1 && $0 != getpid() }
            guard !id.hasPrefix("system"), !safe.isEmpty else {
                throw TerminationError.refused
            }
            return await stopApp(bundleID: id, pids: safe, mode: request.mode)
        case .container:
            // Containers are stopped by the Docker terminator, never with signals.
            throw TerminationError.refused
        }
    }

    private func stopApp(bundleID: String, pids: [Int32], mode: TerminationMode) async -> TerminationResult {
        let asked = await MainActor.run { () -> Int in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != getpid() }
            for app in running {
                if mode == .forceQuit {
                    app.forceTerminate()
                } else {
                    app.terminate()
                }
            }
            return running.count
        }
        if asked == 0 {
            // No GUI app for this identity ("Other" rows): signal its processes directly.
            return await stop(members: pids, mode: mode, signal: { signal in
                pids.reduce(Int32(0)) { status, pid in kill(pid, signal) == 0 ? status : -1 }
            })
        }
        let deadline = ContinuousClock.now + Self.gracePeriod
        while ContinuousClock.now < deadline, pids.contains(where: Self.isAlive) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if mode == .forceQuit {
            // Helpers that outlived their app.
            for pid in pids where Self.isAlive(pid) {
                kill(pid, SIGKILL)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let survivors = pids.filter(Self.isAlive)
        return TerminationResult(terminated: pids.filter { !survivors.contains($0) }, survivors: survivors)
    }

    private func stop(members: [Int32], mode: TerminationMode, signal: (Int32) -> Int32) async -> TerminationResult {
        let first = mode == .forceQuit ? SIGKILL : SIGTERM
        if signal(first) != 0 {
            Self.log.notice("Signal \(first) failed: \(String(cString: strerror(errno)))")
        }
        let deadline = ContinuousClock.now + (mode == .forceQuit ? .seconds(1) : Self.gracePeriod)
        while ContinuousClock.now < deadline, members.contains(where: Self.isAlive) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if mode == .quit, members.contains(where: Self.isAlive) {
            _ = signal(SIGKILL)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let survivors = members.filter(Self.isAlive)
        return TerminationResult(terminated: members.filter { !survivors.contains($0) }, survivors: survivors)
    }

    /// Alive means it exists and isn't a zombie (a zombie has exited; it's only waiting for its
    /// parent to reap it). `kill(pid, 0)` alone reports zombies as alive.
    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 {
            // EPERM: it exists but belongs to someone else.
            return errno == EPERM
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // We may signal it, so a failed read means it's a zombie (bsdinfo refuses those).
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return false
        }
        return info.pbi_status != UInt32(SZOMB)
    }
}

public enum TerminationError: Error, Equatable {
    /// The target was launchd, the kernel, Mactivity, or Mactivity's own process group.
    case refused
}
