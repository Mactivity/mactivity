import Core
import Darwin
import Foundation
import os

/// Each test command in a snapshot, with its project (D-278). Everything here happens once per
/// process: its arguments and its folder when first seen, and only for the few names
/// `TestRunRules.needsArguments` lets through. Each snapshot is otherwise a dictionary lookup.
public struct TestRunLocator {
    private struct Entry {
        let command: TestCommand
        let startedAt: Date
        let project: String
        /// Where it runs, to tell a part of a run from a separate one.
        let folder: String?
        /// The test command this one runs under: its workers, or `jest` under `npm test`.
        let root: Int32?
    }

    /// PID → what it is; nil once looked at and found not to be a test command.
    private var known: [Int32: Entry?] = [:]

    public init() {}

    public mutating func processes(in snapshot: Snapshot) -> [TestProcess] {
        let candidates = snapshot.processes.filter { TestRunRules.needsArguments(name: $0.name) }
        let live = Set(candidates.map(\.pid))
        known = known.filter { live.contains($0.key) }
        let new = candidates.filter { known[$0.pid] == nil }
        var commands: [Int32: TestCommand] = [:]
        var folders: [Int32: String] = [:]
        for process in new {
            let command = TestRunRules.command(name: process.name, arguments: ProcessInspector.arguments(process.pid))
            commands[process.pid] = command
            if let command, let folder = Self.folder(process.pid, command) {
                folders[process.pid] = folder
            }
        }
        for process in new {
            guard let command = commands[process.pid], let identity = ProcessInspector.identity(process.pid) else {
                known[process.pid] = .some(nil)
                continue
            }
            let folder = folders[process.pid]
            let root = root(of: identity.parentPID, folder: folder, newCommands: commands, newFolders: folders)
            known[process.pid] = Entry(
                command: command, startedAt: identity.startedAt, project: root == nil ? Self.project(folder) : "", folder: folder,
                root: root
            )
        }
        // A child's arguments can say what its top process's can't: `npm test` starting a watcher.
        var watching = Set<Int32>()
        var partial = Set<Int32>()
        for case let (_, entry?) in known {
            if let root = entry.root {
                if entry.command.isWatching {
                    watching.insert(root)
                }
                if entry.command.isPartial {
                    partial.insert(root)
                }
            }
        }
        return known.compactMap { pid, entry -> TestProcess? in
            guard let entry, entry.root == nil else {
                return nil
            }
            return TestProcess(
                pid: pid, startedAt: entry.startedAt, tool: entry.command.tool, project: entry.project,
                isPartial: entry.command.isPartial || partial.contains(pid),
                isWatching: entry.command.isWatching || watching.contains(pid)
            )
        }
    }

    /// The nearest test command above this process, a few parents up (`sh -c jest` sits between),
    /// when this one runs inside its folder. A test that runs another project's tests, in some
    /// other folder, starts a run of that project's own.
    private func root(of parent: Int32, folder: String?, newCommands: [Int32: TestCommand], newFolders: [Int32: String]) -> Int32? {
        var next = parent
        for _ in 0 ..< 6 where next > 1 {
            if newCommands[next] != nil {
                return TestRunRules.isInside(folder, newFolders[next]) ? next : nil
            }
            if case let .some(entry?) = known[next] {
                return TestRunRules.isInside(folder, entry.folder) ? entry.root ?? next : nil
            }
            guard let identity = ProcessInspector.identity(next) else {
                return nil
            }
            next = identity.parentPID
        }
        return nil
    }

    private static func folder(_ pid: Int32, _ command: TestCommand) -> String? {
        let directory = ProcessInspector.workingDirectory(pid)
        let named = command.directory.map { path -> String in
            path.hasPrefix("/") ? path : ((directory ?? "") as NSString).appendingPathComponent(path)
        }
        return (named ?? directory).map { ($0 as NSString).standardizingPath }
    }

    private static func project(_ folder: String?) -> String {
        guard let folder, folder != NSHomeDirectory(), folder != "/" else {
            return ""
        }
        return LiveAgentSource.projectName(folder)
    }
}

/// Tells when a process exits, and how: a kernel event per watched process, so nothing polls, and
/// the time is the exit's rather than the next snapshot's. `kevent(2)` documents `NOTE_EXITSTATUS`
/// for child processes only, but macOS reports it for this user's other processes too (checked on
/// macOS 27, D-278). If it refuses, this falls back to the exit alone, and a run's outcome reads
/// `.unknown`, which is counted as finished; if that's refused too, the snapshots end the run.
public final class ProcessExitWatcher: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.mactivity.projects", category: "ProcessExitWatcher")
    private let queue = DispatchQueue(label: "app.mactivity.projects.exit-watcher", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let kernelQueue: Int32
    private let source: DispatchSourceRead?

    private struct State {
        var watched = Set<Int32>()
        var exits: [Int32: ProcessExit] = [:]
    }

    public init() {
        let descriptor = kqueue()
        kernelQueue = descriptor
        guard descriptor >= 0 else {
            source = nil
            Self.log.error("kqueue failed: \(errno)")
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.source = source
        let state = state
        // The queue itself becomes readable when an event waits: no thread sits blocked on it.
        source.setEventHandler {
            Self.collect(descriptor, into: state)
        }
        source.resume()
    }

    deinit {
        source?.cancel()
        if kernelQueue >= 0 {
            close(kernelQueue)
        }
    }

    /// Watches until it exits. Calling again for the same process does nothing.
    public func watch(_ pid: Int32) {
        guard kernelQueue >= 0, state.withLock({ $0.watched.insert(pid).inserted }) else {
            return
        }
        let registered = register(pid, flags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS))
            || (errno != ESRCH && register(pid, flags: UInt32(NOTE_EXIT)))
        // Already gone: nothing will come for it, and its PID may come round again.
        if !registered {
            state.withLock { _ = $0.watched.remove(pid) }
        }
    }

    /// The exits since the last call.
    public func drain() -> [Int32: ProcessExit] {
        state.withLock { state in
            defer { state.exits = [:] }
            return state.exits
        }
    }

    private func register(_ pid: Int32, flags: UInt32) -> Bool {
        var event = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: flags, data: 0, udata: nil
        )
        return kevent(kernelQueue, &event, 1, nil, 0, nil) == 0
    }

    private static func collect(_ descriptor: Int32, into state: OSAllocatedUnfairLock<State>) {
        var events = Array(repeating: Darwin.kevent(), count: 16)
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(descriptor, nil, 0, &events, Int32(events.count), &immediately)
        guard count > 0 else {
            return
        }
        let now = Date()
        let exits = events.prefix(Int(count)).filter { $0.fflags & UInt32(NOTE_EXIT) != 0 }.map { event in
            let hasStatus = event.fflags & UInt32(NOTE_EXITSTATUS) != 0
            return (Int32(event.ident), ProcessExit(at: now, waitStatus: hasStatus ? Int32(truncatingIfNeeded: event.data) : nil))
        }
        state.withLock { state in
            for (pid, exit) in exits {
                state.exits[pid] = exit
                state.watched.remove(pid)
            }
        }
    }
}
