import Darwin
import Foundation
@testable import PrivateAPIs
import Testing

@Suite("Programs that answer for themselves (D-263)")
struct DisclaimedProcessTests {
    final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var value: pid_t?

        var pid: pid_t? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("Its output and exit code come back")
    func output() async throws {
        let done = try #require(await DisclaimedProcess.run(
            path: "/bin/sh",
            arguments: ["-c", "echo hi; exit 3"],
            environment: [:],
            timeout: .seconds(10)
        ))
        #expect(done.status == 3)
        #expect(String(bytes: done.output, encoding: .utf8) == "hi\n")
    }

    @Test("It gets only the environment it was given")
    func environment() async throws {
        let done = try #require(await DisclaimedProcess.run(
            path: "/usr/bin/env", arguments: [], environment: ["ONLY": "this"], timeout: .seconds(10)
        ))
        #expect(String(bytes: done.output, encoding: .utf8) == "ONLY=this\n")
    }

    @Test("It answers for itself, not for the process that started it")
    func responsibleForItself() async throws {
        let started = Started()
        let disclaim = try #require(DisclaimedProcess.disclaim)
        async let finished = DisclaimedProcess.run(
            path: "/bin/sleep", arguments: ["1"], environment: [:], timeout: .seconds(10), disclaim: disclaim, started: { started.pid = $0 }
        )
        try await Task.sleep(for: .milliseconds(300))
        let pid = try #require(started.pid)
        #expect(DisclaimedProcess.responsible(for: pid) == pid)
        #expect(DisclaimedProcess.responsible(for: pid) != getpid())
        _ = await finished
    }

    @Test("It can't use a file Mactivity has open")
    func noInheritedFiles() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        defer {
            close(descriptor)
            unlink(path)
        }
        let done = try #require(await DisclaimedProcess.run(
            path: "/bin/sh", arguments: ["-c", "echo no >&\(descriptor)"], environment: [:], timeout: .seconds(10)
        ))
        #expect(done.status != 0)
    }

    @Test("Past its limit it's stopped, and reads as not finished")
    func timeout() async {
        let done = await DisclaimedProcess.run(path: "/bin/sleep", arguments: ["30"], environment: [:], timeout: .milliseconds(200))
        #expect(done == nil)
    }

    @Test("A program that ends at once is still noticed", .timeLimit(.minutes(1)))
    func endsAtOnce() async {
        for _ in 0 ..< 50 {
            let done = await DisclaimedProcess.run(path: "/usr/bin/true", arguments: [], environment: [:], timeout: .seconds(10))
            #expect(done?.status == 0)
        }
    }

    @Test("Fallback: without the symbol nothing starts")
    func fallback() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ran-\(UUID().uuidString)").path
        let done = await DisclaimedProcess.run(
            path: "/usr/bin/touch", arguments: [marker], environment: [:], timeout: .seconds(5), disclaim: nil
        )
        #expect(done == nil)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("A program that can't start reads as nil")
    func missing() async {
        #expect(await DisclaimedProcess.run(path: "/nonexistent/brew", arguments: [], environment: [:], timeout: .seconds(1)) == nil)
    }

    @Test("Exit statuses")
    func exitCodes() {
        #expect(DisclaimedProcess.exitCode(0) == 0)
        #expect(DisclaimedProcess.exitCode(1 << 8) == 1)
        #expect(DisclaimedProcess.exitCode(15) == nil)
    }
}
