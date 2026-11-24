import Darwin
@testable import PrivateAPIs
import Testing

@Suite("Responsible PID")
struct ResponsiblePIDTests {
    @Test("Missing symbol returns nil so callers use the ppid walk")
    func fallback() {
        #expect(ResponsiblePID.lookup(getpid(), using: nil) == nil)
    }

    @Test("A failing lookup (negative result) returns nil")
    func failure() {
        let failing: @convention(c) (pid_t) -> pid_t = { _ in -1 }
        #expect(ResponsiblePID.lookup(1234, using: failing) == nil)
    }

    @Test("On this macOS the symbol resolves and our own PID has a responsible process")
    func live() throws {
        try #require(ResponsiblePID.isAvailable)
        #expect(ResponsiblePID.lookup(getpid()) != nil)
    }
}
