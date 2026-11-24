import Core
import Foundation
@testable import Readouts
import Testing

@Suite("App ranking")
struct AppRankingTests {
    private func names(_ ranking: AppRanking, limit: Int = 10, includingSystem: Bool = true) throws -> [String] {
        try ranking.rank(Fixtures.snapshot().apps, limit: limit, includingSystem: includingSystem).map(\.app.name)
    }

    @Test("CPU, highest first, macOS included by default")
    func cpu() throws {
        #expect(try names(.cpu) == ["Xcode", "node", "macOS", "Safari", "Slack", "Terminal"])
    }

    @Test("Excluding the macOS row, as the widgets and Shortcuts do")
    func excludingSystem() throws {
        #expect(try names(.cpu, limit: 3, includingSystem: false) == ["Xcode", "node", "Safari"])
    }

    @Test("Apps without a figure sort last")
    func missingLast() throws {
        #expect(try names(.energy).last == "node")
    }

    @Test("Disk combines read and write; ties break by name")
    func disk() throws {
        #expect(try names(.disk) == ["Xcode", "macOS", "Safari", "node", "Slack", "Terminal"])
    }

    @Test("Per-app network is unavailable, so the order is by name and every figure is a dash")
    func network() throws {
        #expect(try names(.network) == ["macOS", "node", "Safari", "Slack", "Terminal", "Xcode"])
        let apps = try Fixtures.snapshot().apps
        #expect(apps.allSatisfy { AppRanking.network.formatted($0, locale: Fixtures.english) == "–" })
    }

    @Test("Limit caps the list; zero or negative is empty")
    func limit() throws {
        #expect(try names(.memory, limit: 2) == ["macOS", "Xcode"])
        #expect(try names(.memory, limit: 0).isEmpty)
        #expect(try names(.memory, limit: -3).isEmpty)
    }

    @Test("Figures format the way the app shows them")
    func formatting() throws {
        let apps = try Fixtures.snapshot().apps
        let xcode = try #require(apps.first { $0.app.name == "Xcode" })
        #expect(AppRanking.cpu.formatted(xcode, locale: Fixtures.english) == "13%")
        #expect(AppRanking.memory.formatted(xcode, locale: Fixtures.english) == "6.2 GB")
        #expect(AppRanking.energy.formatted(xcode, locale: Fixtures.english) == "4.1 W")
        #expect(AppRanking.disk.formatted(xcode, locale: Fixtures.english) == "1.2 MB/s")
    }
}
