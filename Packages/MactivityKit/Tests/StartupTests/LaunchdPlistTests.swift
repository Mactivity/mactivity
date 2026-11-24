import Foundation
@testable import Startup
import Testing

@Suite("launchd plist parsing")
struct LaunchdPlistTests {
    @Test("Program wins over ProgramArguments[0]; arguments drop the executable")
    func program() throws {
        let plist = try StartupFixtures.plist("program")
        #expect(plist.label == "com.docker.vmnetd")
        #expect(plist.program == "/Library/PrivilegedHelperTools/com.docker.vmnetd")
        #expect(plist.declaredExecutable == "/Library/PrivilegedHelperTools/com.docker.vmnetd")
        #expect(plist.extraArguments == ["--verbose"])
        #expect(plist.runAtLoad)
        #expect(plist.keepAlive == .off)
        #expect(plist.onDemandTriggers == ["Sockets"])
        #expect(plist.schedule == .atLoad)
    }

    @Test("ProgramArguments only, StartInterval, KeepAlive false, AssociatedBundleIdentifiers as an array")
    func programArguments() throws {
        let plist = try StartupFixtures.plist("program-arguments")
        #expect(plist.program == nil)
        #expect(plist.declaredExecutable?.hasSuffix("/GoogleUpdater.app/Contents/MacOS/GoogleUpdater") == true)
        #expect(plist.extraArguments == ["--wake-all", "--enable-logging"])
        #expect(plist.startInterval == 3600)
        #expect(plist.keepAlive == .off)
        #expect(plist.associatedBundleIdentifiers == ["com.google.GoogleUpdater"])
        #expect(plist.schedule == .interval(seconds: 3600, atLoad: false))
    }

    @Test("BundleProgram is kept relative until there's a bundle")
    func bundleProgram() throws {
        let plist = try StartupFixtures.plist("bundle-program")
        #expect(plist.bundleProgram == "Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel")
        #expect(plist.extraArguments == ["background"])
        #expect(plist.schedule == .atLoad)
    }

    @Test("StartCalendarInterval as a single dictionary")
    func calendarDictionary() throws {
        let plist = try StartupFixtures.plist("calendar-dict")
        #expect(plist.calendarIntervals == [CalendarInterval(minute: 15, hour: 3)])
        #expect(plist.schedule == .calendar([CalendarInterval(minute: 15, hour: 3)], atLoad: false))
    }

    @Test("StartCalendarInterval as an array skips entries that aren't dictionaries")
    func calendarArray() throws {
        let plist = try StartupFixtures.plist("calendar-array")
        #expect(plist.calendarIntervals == [
            CalendarInterval(minute: 0, hour: 9, weekday: 0),
            CalendarInterval(minute: 0, hour: 9, weekday: 3),
        ])
        #expect(plist.schedule == .calendar(plist.calendarIntervals, atLoad: true))
    }

    @Test("KeepAlive as a dictionary of conditions beats StartInterval")
    func keepAliveDictionary() throws {
        let plist = try StartupFixtures.plist("keepalive-dict")
        #expect(plist.keepAlive == .conditions(["NetworkState", "SuccessfulExit"]))
        #expect(plist.startInterval == 600)
        #expect(plist.schedule == .alwaysRunning(conditional: true))
    }

    @Test("KeepAlive true, from XML and from a binary plist")
    func keepAliveTrue() throws {
        for name in ["keepalive-true", "binary"] {
            let plist = try StartupFixtures.plist(name)
            #expect(plist.keepAlive == .always)
            #expect(plist.schedule == .alwaysRunning(conditional: false))
            #expect(plist.programArguments.first == "/opt/homebrew/opt/postgresql@17/bin/postgres")
        }
    }

    @Test("Disabled, and AssociatedBundleIdentifiers as a single string")
    func disabled() throws {
        let plist = try StartupFixtures.plist("disabled")
        #expect(plist.disabled)
        #expect(plist.associatedBundleIdentifiers == ["com.microsoft.autoupdate2"])
    }

    @Test("Wrong-typed keys are ignored, as launchd ignores them")
    func wrongTypes() throws {
        let plist = try StartupFixtures.plist("wrong-types")
        #expect(plist.runAtLoad == false)
        #expect(plist.keepAlive == .off)
        #expect(plist.startInterval == nil)
        #expect(plist.disabled == false)
        #expect(plist.programArguments == ["sh", "-c", "echo hello"])
        #expect(plist.schedule == .onDemand)
    }

    @Test("An empty dictionary parses to nothing")
    func empty() throws {
        let plist = try StartupFixtures.plist("empty")
        #expect(plist == LaunchdPlist())
        #expect(plist.declaredExecutable == nil)
    }

    @Test("Not a property list throws")
    func notAPlist() throws {
        let data = try StartupFixtures.data("not-a-plist")
        #expect(throws: LaunchdPlist.ParseError.notADictionary) { try LaunchdPlist.parse(data) }
    }
}

@Suite("Schedule words")
struct StartupTextTests {
    @Test(
        "Schedules read as a person would say them",
        arguments: [
            (StartupSchedule.atLoad, StartupKind.agent, "At login"),
            (.atLoad, .daemon, "At startup"),
            (.alwaysRunning(conditional: false), .agent, "Always running"),
            (.alwaysRunning(conditional: true), .agent, "Kept running"),
            (.interval(seconds: 3600, atLoad: false), .agent, "Every 1h"),
            (.interval(seconds: 5400, atLoad: true), .agent, "At login, then every 1h 30m"),
            (.interval(seconds: 45, atLoad: false), .daemon, "Every 45s"),
            (
                .calendar([CalendarInterval(minute: 15, hour: 3)], atLoad: false),
                .agent,
                "Daily at \(StartupText.clock(hour: 3, minute: 15))"
            ),
            (
                .calendar([CalendarInterval(minute: 0, hour: 9, weekday: 7)], atLoad: false),
                .agent,
                "Weekly on Sunday at \(StartupText.clock(hour: 9, minute: 0))"
            ),
            (.calendar([CalendarInterval(minute: 30)], atLoad: false), .agent, "Hourly at :30"),
            (
                .calendar([CalendarInterval(hour: 4, day: 1)], atLoad: true),
                .daemon,
                "At startup, then monthly on day 1, every minute of \(StartupText.clock(hour: 4, minute: 0))"
            ),
            (.calendar([CalendarInterval(), CalendarInterval()], atLoad: false), .agent, "On a schedule (2 times)"),
            (.onDemand, .agent, "On demand"),
        ]
    )
    func schedule(_ schedule: StartupSchedule, _ kind: StartupKind, _ expected: String) {
        #expect(StartupText.schedule(schedule, kind: kind) == expected)
    }

    @Test("Intervals in whole units")
    func interval() {
        #expect(StartupText.interval(0) == "0s")
        #expect(StartupText.interval(60) == "1m")
        #expect(StartupText.interval(86400) == "1d")
        #expect(StartupText.interval(90061) == "1d 1h 1m 1s")
    }
}
