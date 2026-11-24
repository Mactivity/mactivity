import Core
import Darwin
import Foundation
@testable import Sampling
import Testing

@Suite("Privileged helper client")
struct HelperTests {
    @Test("Requirements pin identifier, Apple anchor, and team")
    func requirement() {
        #expect(HelperIdentity.requirement(identifier: "app.mactivity.Mactivity", teamID: "ABCDE12345")
            == "identifier \"app.mactivity.Mactivity\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test("No team, a malformed team, or an injected one gives no requirement", arguments: [
        nil, "", "SHORT", "ABCDE12345\" or true", "ABCDE1234!",
    ] as [String?])
    func noRequirement(teamID: String?) {
        #expect(HelperIdentity.requirement(identifier: "x", teamID: teamID) == nil)
    }

    @Test("Without a team ID the client never enables and reads processes locally")
    func fallsBack() async throws {
        let source = HelperProcessSource(teamID: nil)
        await source.setEnabled(true)
        let readings = try await source.sample()
        #expect(readings.contains { $0.pid == getpid() && $0.isComplete })
    }

    @Test("With a team but no helper installed, a tick still completes locally within the timeout")
    func unreachableHelper() async throws {
        let source = HelperProcessSource(teamID: "ABCDE12345")
        await source.setEnabled(true)
        let elapsed = try await ContinuousClock().measure {
            let readings = try await source.sample()
            #expect(readings.contains { $0.pid == getpid() })
        }
        #expect(elapsed < .seconds(2))
    }
}
