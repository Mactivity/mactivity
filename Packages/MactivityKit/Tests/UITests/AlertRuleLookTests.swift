import Core
import Testing
@testable import UI

/// Every rule shows in the Rules view, once (D-239).
struct AlertRuleLookTests {
    @Test("Each alert rule is in exactly one group")
    func everyRuleGrouped() {
        let grouped = AlertRule.Group.allCases.flatMap(\.rules)
        #expect(grouped.count == AlertRule.allCases.count)
        #expect(Set(grouped) == Set(AlertRule.allCases))
    }
}
