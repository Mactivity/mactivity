import Darwin
import Foundation
import os

/// Runs a program that answers to macOS for itself (D-263), so it doesn't inherit Mactivity's
/// Full Disk Access.
///
/// macOS judges a program's file access by its "responsible" process, normally the app that
/// started it. That's safe for the system's own tools, which can't be replaced, but Homebrew is
/// a script in a folder anything running as this user can change, and `brew` runs code from
/// every tap. Started the ordinary way it would have everything Mactivity was given.
///
/// - Symbol: `responsibility_spawnattrs_setdisclaim`, found with `dlsym`.
/// - Framework: libSystem (libquarantine), private. Terminal, Chromium and LLDB use it for this.
/// - If Apple removes it: `run` returns nil without starting anything, so what `brew` would have
///   said goes unread. Nothing runs with Mactivity's access in its place.
public enum DisclaimedProcess {
    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "process")

    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    static let disclaim: Disclaim? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"
    ).map { unsafeBitCast($0, to: Disclaim.self) }

    public struct Finished: Equatable, Sendable {
        public let status: Int32
        public let output: Data
    }

    /// Runs `path` with no terminal and nothing to answer, stopping it after `timeout`. Nil when
    /// it couldn't start, or was stopped or killed before finishing.
    public static func run(path: String, arguments: [String], environment: [String: String], timeout: Duration) async -> Finished? {
        await run(path: path, arguments: arguments, environment: environment, timeout: timeout, disclaim: disclaim)
    }

    static func run(
        path: String, arguments: [String], environment: [String: String], timeout: Duration,
        disclaim: Disclaim?,
        started: @Sendable (pid_t) -> Void = { _ in }
    ) async -> Finished? {
        guard let disclaim else {
            log.error("Can't start a program on its own responsibility; not starting it")
            return nil
        }
        let pipe = Pipe()
        let output = Output()
        guard let pid = spawn(
            path: path, arguments: arguments, environment: environment,
            stdout: pipe.fileHandleForWriting.fileDescriptor, disclaim: disclaim
        ) else {
            return nil
        }
        started(pid)
        // This end belongs to the child now; holding it open would mean never seeing the end.
        try? pipe.fileHandleForWriting.close()
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }

        let state = Exit(pid)
        let limit = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, state.stop() {
                log.error("\((path as NSString).lastPathComponent, privacy: .public) ran past its limit; stopping it")
            }
        }
        let status = await withCheckedContinuation { continuation in
            // Told when it ends, rather than blocking a thread for as long as it runs. macOS keeps
            // an ended program's process ID reserved until it's collected, so `stop` is safe until then.
            let ended = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            ended.setEventHandler {
                ended.cancel()
                continuation.resume(returning: state.collect())
            }
            ended.resume()
        }
        limit.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return status.map { Finished(status: $0, output: output.data) }
    }

    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything else, so the child can't use a file
    /// Mactivity has open, such as the history database.
    private static func spawn(
        path: String,
        arguments: [String],
        environment: [String: String],
        stdout: Int32,
        disclaim: Disclaim
    ) -> pid_t? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // A Swift task's thread has its signals blocked, and a child inherits that: without these
        // two it would never hear SIGTERM, and a time limit would do nothing.
        var noSignals: sigset_t = 0
        var allSignals: sigset_t = ~0
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        guard disclaim(&attributes, 1) == 0, posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else {
            log.error("Couldn't set up a program to run on its own responsibility")
            return nil
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else {
            return nil
        }
        return pid
    }

    /// Which process answers for `pid`, for the tests that check the disclaim took.
    static func responsible(for pid: pid_t) -> pid_t? {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Lookup.self)(pid) }
    }

    /// Pure: a `waitpid` status as an exit code, or nil when a signal ended it.
    static func exitCode(_ status: Int32) -> Int32? {
        status & 0x7F == 0 ? (status >> 8) & 0xFF : nil
    }

    /// The running program. The lock keeps `stop` from signalling a process ID that's been
    /// collected, which macOS could by then have given to something else.
    private final class Exit: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        private var collected = false

        init(_ pid: pid_t) {
            self.pid = pid
        }

        func stop() -> Bool {
            lock.withLock {
                guard !collected else {
                    return false
                }
                kill(pid, SIGTERM)
                return true
            }
        }

        /// Called once it has ended, so this doesn't wait.
        func collect() -> Int32? {
            lock.withLock {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                collected = true
                return DisclaimedProcess.exitCode(status)
            }
        }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.withLock { buffer.append(data) }
        }

        var data: Data {
            lock.withLock { buffer }
        }
    }
}
