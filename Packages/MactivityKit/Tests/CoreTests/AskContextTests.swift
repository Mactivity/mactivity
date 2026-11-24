import Core
import Foundation
import Simulated
import Testing

@Suite("Ask Mactivity's context (D-153)")
struct AskContextTests {
    @Test("The figures, the busiest apps and the diagnosis, in a few hundred words")
    func describe() async {
        let snapshot = await SimulatedSnapshotSource().next()
        let cause = SlowdownCause(kind: .busyApp, severity: .minor, title: "Xcode is using 2 cores", detail: "Quit it if idle.")
        let text = AskContext.describe(snapshot, causes: [cause], now: Date())
        #expect(text.contains("CPU:"))
        #expect(text.contains("Memory:"))
        #expect(text.contains("Busiest apps by CPU:"))
        #expect(text.contains("Xcode is using 2 cores"))
        #expect(text.split(separator: " ").count < 400)
        #expect(AskContext.describe(nil, causes: [], now: Date()).contains("No figures yet"))
    }

    @Test("Questions, not names")
    func questions() {
        #expect(AskContext.looksLikeQuestion("why is my fan loud?"))
        #expect(AskContext.looksLikeQuestion("what used the most battery today"))
        #expect(AskContext.looksLikeQuestion("is Xcode slow"))
        #expect(!AskContext.looksLikeQuestion("Safari"))
        #expect(!AskContext.looksLikeQuestion("Google Chrome"))
        #expect(!AskContext.looksLikeQuestion(":3000"))
    }

    @Test("Quick Search offers Ask first for a question, only when it can")
    func quickSearch() async {
        let snapshot = await SimulatedSnapshotSource().next()
        let asked = QuickSearch.results("why is my mac hot", snapshot: snapshot, projects: [], canAsk: true)
        #expect(asked.first == .ask("why is my mac hot"))
        let cannot = QuickSearch.results("why is my mac hot", snapshot: snapshot, projects: [], canAsk: false)
        #expect(!cannot.contains(.ask("why is my mac hot")))
        let name = QuickSearch.results("Safari", snapshot: snapshot, projects: [], canAsk: true)
        #expect(!name.contains {
            if case .ask = $0 {
                true
            } else {
                false
            }
        })
        // Three words could be an app's name: what matches comes first, Ask last.
        let words = QuickSearch.results("Visual Studio Code", snapshot: snapshot, projects: [], canAsk: true)
        #expect(words.last == .ask("Visual Studio Code"))
        #expect(AskContext.isPlainQuestion("what is using my memory"))
        #expect(!AskContext.isPlainQuestion("Visual Studio Code"))
    }

    @Test("Questions in other languages and with a full-width question mark offer Ask (D-221)")
    func otherLanguages() {
        #expect(AskContext.isPlainQuestion("なぜ遅い？"))
        #expect(AskContext.isPlainQuestion("为什么这么慢？"))
        #expect(AskContext.isPlainQuestion("warum ist es langsam"))
        #expect(AskContext.isPlainQuestion("Pourquoi mon Mac rame"))
        #expect(AskContext.isPlainQuestion("¿Por qué va lento"))
        #expect(!AskContext.isPlainQuestion("Visual Studio Code"))
        #expect(!AskContext.looksLikeQuestion("遅い"))
    }
}
