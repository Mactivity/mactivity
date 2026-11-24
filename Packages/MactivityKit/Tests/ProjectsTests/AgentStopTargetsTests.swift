import Core
import Foundation
@testable import Projects
import Testing

@Suite("Agent Stop targets (D-148)")
struct AgentStopTargetsTests {
    @Test("The agent's group, then each process it started in a group of its own (Claude Code's shells)")
    func outsideTheGroup() {
        #expect(LiveAgentSource.targets(group: 1666, root: 1666, outside: [49877, 49900])
            == [.processGroup(1666), .process(49877), .process(49900)])
        #expect(LiveAgentSource.targets(group: nil, root: 10, outside: [11]) == [.process(10), .process(11)])
    }
}
