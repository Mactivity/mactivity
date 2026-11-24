import Core
import Foundation
@testable import Projects
import Testing

/// Homebrew services (D-225).
struct HomebrewServicesTests {
    @Test("Formulae from launchd plist names")
    func formula() {
        #expect(HomebrewServiceRules.formula(plistName: "homebrew.mxcl.postgresql@16.plist") == "postgresql@16")
        #expect(HomebrewServiceRules.formula(plistName: "homebrew.mxcl.redis.plist") == "redis")
        #expect(HomebrewServiceRules.formula(plistName: "com.docker.helper.plist") == nil)
        #expect(HomebrewServiceRules.formula(plistName: "homebrew.mxcl..plist") == nil)
    }

    @Test("A service's processes: launchd's child in the keg and what it started, not a psql from Terminal")
    func processes() {
        let keg = "/opt/homebrew/Cellar/postgresql@16"
        let table: [HomebrewServiceRules.Process] = [
            .init(pid: 800, parentPID: 1, executable: keg + "/bin/postgres"),
            .init(pid: 801, parentPID: 800, executable: keg + "/bin/postgres"),
            .init(pid: 802, parentPID: 801, executable: keg + "/bin/postgres"),
            .init(pid: 900, parentPID: 640, executable: keg + "/bin/psql"),
            .init(pid: 640, parentPID: 600, executable: "/bin/zsh"),
            .init(pid: 700, parentPID: 1, executable: "/opt/homebrew/Cellar/postgresql@16/16.40/bin/postgres"),
        ]
        // 700 runs an older version after `brew upgrade`: still the service's.
        #expect(Set(HomebrewServiceRules.processes(inKeg: keg, among: table)) == [700, 800, 801, 802])
    }

    @Test("A service run by another formula's program counts by its keg in the arguments")
    func javaService() {
        let keg = "/opt/homebrew/Cellar/kafka"
        let table: [HomebrewServiceRules.Process] = [
            .init(pid: 900, parentPID: 1, name: "java", executable: "/opt/homebrew/Cellar/openjdk/24/bin/java", arguments: [
                "java", "-cp", "/opt/homebrew/opt/kafka/libexec/libs/*", "kafka.Kafka",
            ]),
            .init(pid: 901, parentPID: 900, name: "java", executable: "/opt/homebrew/Cellar/openjdk/24/bin/java"),
            .init(
                pid: 950,
                parentPID: 1,
                name: "java",
                executable: "/opt/homebrew/Cellar/openjdk/24/bin/java",
                arguments: ["java", "-jar", "other.jar"]
            ),
        ]
        let pids = HomebrewServiceRules.processes(inKeg: keg, opt: "/opt/homebrew/opt/kafka", among: table)
        #expect(pids == [900, 901])
        #expect(HomebrewServiceRules.historyName(
            pids: pids,
            table: table,
            program: "/opt/homebrew/opt/kafka/bin/kafka-server-start",
            formula: "kafka"
        ) == "java")
    }

    @Test("A service started through a shell script: the script's shell and what it starts")
    func wrapperScript() {
        let table: [HomebrewServiceRules.Process] = [
            .init(pid: 700, parentPID: 1, name: "mysqld_safe", executable: "/bin/sh", arguments: [
                "/bin/sh", "/opt/homebrew/opt/mysql/bin/mysqld_safe", "--datadir=/opt/homebrew/var/mysql",
            ]),
            .init(pid: 701, parentPID: 700, name: "mysqld", executable: "/opt/homebrew/Cellar/mysql/9.4.0/bin/mysqld"),
        ]
        let pids = HomebrewServiceRules.processes(inKeg: "/opt/homebrew/Cellar/mysql", opt: "/opt/homebrew/opt/mysql", among: table)
        #expect(pids == [700, 701])
        #expect(HomebrewServiceRules.historyName(pids: [701], table: table, program: nil, formula: "mysql") == "mysqld")
    }

    @Test("Last busy: the newest hour at 1% of a core or more")
    func lastBusy() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let points = [
            SeriesPoint(at: t0, average: 4, maximum: 9),
            SeriesPoint(at: t0 + 3600, average: 0.2, maximum: 3),
            SeriesPoint(at: t0 + 7200, average: 0.1, maximum: 0.5),
        ]
        #expect(HomebrewServiceRules.lastBusy(points) == t0)
        #expect(HomebrewServiceRules.lastBusy(Array(points.dropFirst())) == nil)
    }

    @Test("Average processor since start, and the stop command")
    func figures() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let service = HomebrewService(
            formula: "nginx", plistPath: "/Library/LaunchDaemons/homebrew.mxcl.nginx.plist", asRoot: true, pids: [5], cpuSeconds: 36,
            startedAt: now - 3600, executableName: "nginx"
        )
        #expect(service.averageCPU(now: now) == 1)
        #expect(service.stopCommand == "sudo brew services stop nginx")
    }
}
