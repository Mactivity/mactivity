import Core
import Foundation
@testable import Protections
import Testing

@Suite("Configuration profiles (D-287)")
struct ProfilesParsingTests {
    /// Real output on macOS 27.2, with the user's name and the UUIDs replaced.
    static let real = """
    someone[1] attribute: name: ManagedSettings User Settings
    someone[1] attribute: configurationDescription: (null)
    someone[1] attribute: installationDate: 2026-10-30 18:42:43 +0000
    someone[1] attribute: organization: (null)
    someone[1] attribute: profileIdentifier: com.apple.ManagedSettings.macOS.00000000-0000-4000-8000-000000000001
    someone[1] attribute: profileUUID: 00000000-0000-4000-8000-000000000001
    someone[1] attribute: profileType: Configuration
    someone[1] attribute: removalDisallowed: FALSE
    someone[1] attribute: version: 1
    someone[1] attribute: containsComputerItems: FALSE
    someone[1] attribute: installedByMDM: FALSE
    someone[1] attribute: internaldata: TRUE
    someone[1] payload count = 1
    someone[1]            payload[1] name\t\t\t= (null)
    someone[1]            payload[1] description\t\t= (null)
    someone[1]            payload[1] type\t\t\t= com.apple.familycontrols.contentfilter
    someone[1]            payload[1] organization\t\t= (null)
    someone[1]            payload[1] identifier\t\t= com.apple.ManagedSettings.macOS.00000000-0000-4000-8000-000000000002
    someone[1]            payload[1] uuid\t\t\t= 00000000-0000-4000-8000-000000000002
    There are 1 user configuration profiles installed for 'someone'
    """

    @Test("The real listing: Screen Time's profile, with its date and what it changes")
    func real() throws {
        let found = try #require(ProfilesParsing.profiles(Self.real))
        #expect(found.count == 1)
        let profile = try #require(found.first)
        #expect(profile.name == "ManagedSettings User Settings")
        #expect(profile.organization == nil)
        #expect(profile.description == nil)
        #expect(profile.installed == Date(timeIntervalSince1970: 1_793_385_763))
        #expect(!profile.installedByManagement)
        #expect(!profile.removalDisallowed)
        #expect(profile.isInternal)
        #expect(profile.payloads == [ProfilePayload(type: "com.apple.familycontrols.contentfilter", name: nil)])
        #expect(profile.origin == .screenTime)
    }

    @Test("Several profiles and several payloads stay apart")
    func several() throws {
        let found = try #require(ProfilesParsing.profiles("""
        a b[1] attribute: name: First
        a b[1] attribute: profileIdentifier: com.example.first
        a b[1] attribute: organization: Example Inc.
        a b[1] attribute: removalDisallowed: TRUE
        a b[1] payload count = 2
        a b[1]            payload[1] name\t= Office
        a b[1]            payload[1] type\t= com.apple.wifi.managed
        a b[1]            payload[2] name\t= (null)
        a b[1]            payload[2] type\t= com.apple.security.root
        a b[2] attribute: profileIdentifier: com.example.second
        a b[2] attribute: installedByMDM: TRUE
        There are 2 user configuration profiles installed for 'a b'
        """))
        #expect(found.map(\.identifier) == ["com.example.first", "com.example.second"])
        #expect(found[0].payloads.map(\.type) == ["com.apple.wifi.managed", "com.apple.security.root"])
        #expect(found[0].payloads[0].name == "Office")
        #expect(found[0].removalDisallowed)
        #expect(found[0].origin == .named("Example Inc."))
        #expect(found[1].origin == .management(organization: nil))
    }

    @Test("None installed reads as none; a refusal or new wording as can't read")
    func noneOrRefused() {
        #expect(ProfilesParsing.profiles("There are no configuration profiles installed") == [])
        #expect(ProfilesParsing.profiles("profiles: this command requires root privileges") == nil)
        #expect(ProfilesParsing.profiles("") == nil)
    }

    @Test("Who put it there: management first, and Apple's name only counts when macOS wrote it")
    func origin() {
        func profile(
            _ id: String, internal isInternal: Bool = false, mdm: Bool = false, organization: String? = nil
        ) -> ConfigurationProfile {
            ConfigurationProfile(identifier: id, name: nil, organization: organization, installedByManagement: mdm, isInternal: isInternal)
        }
        #expect(profile("com.apple.ManagedSettings.macOS.x", internal: true).origin == .screenTime)
        #expect(profile("com.apple.other", internal: true).origin == .macOS)
        #expect(profile("com.apple.ManagedSettings.macOS.x").origin == .unnamed)
        #expect(profile("com.apple.fake", organization: "Apple").origin == .named("Apple"))
        #expect(profile("x", mdm: true, organization: "Acme").origin == .management(organization: "Acme"))
        #expect(profile("x").origin == .unnamed)
    }

    @Test("Enrollment: the real answer, and the Yes macOS can add to")
    func enrollment() {
        let no = ProfilesParsing.enrollment("Enrolled via DEP: No\nMDM enrollment: No\n")
        #expect(no == ManagementEnrollment(automated: false, managed: false))
        let yes = ProfilesParsing.enrollment("Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\n")
        #expect(yes == ManagementEnrollment(automated: true, managed: true))
        #expect(ProfilesParsing.enrollment("something else") == nil)
    }

    @Test(
        "Live: this Mac's profiles command answers",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil)
    )
    func live() async {
        #expect(await LiveProfiles().read() != nil)
    }
}
