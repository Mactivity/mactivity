import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Crash reports (D-098)")
struct CrashReportTests {
    @Test("A crash from an .ips header: app, bundle ID, time")
    func crash() throws {
        let line = #"{"app_name":"Safari","timestamp":"2026-09-23 14:52:07.00 -0700","#
            + #""bundleID":"com.apple.Safari","bug_type":"309","name":"Safari"}"#
        let report = try #require(LiveCrashReports.parse(fileName: "Safari-2026-09-23-145207.ips", firstLine: line, path: "/r"))
        #expect(report.appName == "Safari")
        #expect(report.bundleID == "com.apple.Safari")
        #expect(report.kind == .crash)
        #expect(report.at == Date(timeIntervalSince1970: 1_790_200_327))
        #expect(report.appVersion == nil)
        let versioned = line.replacingOccurrences(of: #""bug_type""#, with: #""app_version":"26.1","bug_type""#)
        #expect(LiveCrashReports.parse(fileName: "Safari.ips", firstLine: versioned, path: "/r")?.appVersion == "26.1")
    }

    @Test("Faults the app survived, other report types and non-JSON lines are left out")
    func skipped() {
        let line = #"{"app_name":"Stocks","timestamp":"2026-09-23 18:59:21.00 -0700","bug_type":"309"}"#
        #expect(LiveCrashReports.parse(fileName: "ExcUserFault_Stocks-2026-09-23-185921.ips", firstLine: line, path: "/r") == nil)
        let analytics = #"{"bug_type":"211","timestamp":"2026-09-23 18:59:21.00 -0700"}"#
        #expect(LiveCrashReports.parse(fileName: "Analytics-2026-09-23.ips", firstLine: analytics, path: "/r") == nil)
        #expect(LiveCrashReports.parse(fileName: "x.ips", firstLine: "not json", path: "/r") == nil)
    }

    @Test("A hang from its file name")
    func hang() throws {
        let report = try #require(LiveCrashReports.parse(fileName: "Xcode_2026-09-23-145207_Mac.hang", firstLine: "", path: "/r"))
        #expect(report.appName == "Xcode")
        #expect(report.kind == .hang)
    }
}
