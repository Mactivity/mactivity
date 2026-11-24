import Core
import Foundation
@testable import Startup
import Testing

/// New startup items (D-231).
struct StartupWatchTests {
    private func item(
        _ label: String, kind: StartupKind = .agent, location: StartupLocation = .userLaunchAgents, state: StartupState = .on
    ) -> StartupItem {
        StartupItem(
            id: "/x/\(label).plist", label: label, name: label, kind: kind, location: location, plistPath: "/x/\(label).plist",
            executablePath: nil, arguments: [], schedule: .atLoad, plist: nil,
            owner: StartupOwner(name: "Google Chrome", bundleID: "com.google.Chrome", bundlePath: nil, evidence: .labelPrefix),
            state: state, loginItemsStatus: nil, isRunning: nil, flags: []
        )
    }

    @Test("The first look learns; later ones report what's new, once")
    func additions() {
        let first = StartupWatch.additions([item("a"), item("b")], known: nil)
        #expect(first.new.isEmpty)
        let second = StartupWatch.additions([item("a"), item("b"), item("com.google.keystone.agent")], known: first.known)
        #expect(second.new.map(\.label) == ["com.google.keystone.agent"])
        #expect(StartupWatch.additions([item("a"), item("b"), item("com.google.keystone.agent")], known: second.known).new.isEmpty)
    }

    @Test("Something that puts itself back beside Mactivity's disabled copy is new again")
    func comesBack() {
        let disabled = item("com.google.keystone.agent", location: .disabledByMactivity)
        let before = StartupWatch.additions([item("a"), disabled], known: [])
        #expect(before.new.map(\.label) == ["a"])
        let back = StartupWatch.additions([item("a"), disabled, item("com.google.keystone.agent")], known: before.known)
        #expect(back.new.map(\.label) == ["com.google.keystone.agent"])
    }

    @Test("Turned on in Mactivity: not news")
    func acknowledged() throws {
        let defaults = try #require(UserDefaults(suiteName: "StartupWatchTests-\(UUID().uuidString)"))
        defaults.set(["agent:a"], forKey: StartupWatch.defaultsKey)
        StartupWatch.acknowledge(item("b"), in: defaults)
        let known = Set(defaults.stringArray(forKey: StartupWatch.defaultsKey) ?? [])
        #expect(StartupWatch.additions([item("a"), item("b")], known: known).new.isEmpty)
    }

    @Test("The alert names the app and what was added")
    func addition() {
        let addition = StartupWatch.addition(item("com.google.keystone.agent"))
        #expect(addition.name == "Google Chrome")
        #expect(addition.what.contains("login"))
    }

    @Test("A helper an app only ships isn't news; it is once it's on (D-236)")
    func registeredOnly() {
        let first = StartupWatch.additions([item("a")], known: nil)
        let shipped = StartupWatch.additions(
            [item("a"), item("com.app.helper", kind: .appHelper, state: .notRegistered)],
            known: first.known
        )
        #expect(shipped.new.isEmpty)
        let on = StartupWatch.additions([item("a"), item("com.app.helper", kind: .appHelper)], known: shipped.known)
        #expect(on.new.map(\.label) == ["com.app.helper"])
    }

    @Test("Several added by one app at once are one alert")
    func grouped() {
        let additions = StartupWatch.additions(grouping: [item("com.google.keystone.agent"), item("com.google.keystone.xpcservice")])
        #expect(additions.count == 1)
        #expect(additions.first?.what.contains("2") == true)
    }
}
