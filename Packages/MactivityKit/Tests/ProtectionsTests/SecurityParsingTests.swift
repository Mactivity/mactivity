import Core
import Foundation
@testable import Protections
import Testing

@Suite("Security settings and extensions (D-261)")
struct SecurityParsingTests {
    @Test("Settings from each command, as this Mac prints them")
    func settings() {
        #expect(SecurityParsing.fileVault("FileVault is On.\n") == true)
        #expect(SecurityParsing.fileVault("FileVault is Off.\n") == false)
        #expect(SecurityParsing.fileVault("") == nil)
        #expect(SecurityParsing.systemIntegrity("System Integrity Protection status: enabled.") == true)
        #expect(SecurityParsing.systemIntegrity("System Integrity Protection status: enabled (Custom Configuration).") == true)
        #expect(SecurityParsing.systemIntegrity("System Integrity Protection status: disabled.") == false)
        #expect(SecurityParsing.gatekeeper("assessments enabled\n") == true)
        #expect(SecurityParsing.gatekeeper("assessments disabled\n") == false)
        #expect(LiveSecurity.firewallState("Firewall is disabled. (State = 0)") == false)
        #expect(LiveSecurity.firewallState("Firewall is enabled. (State = 1)") == true)
    }

    @Test("Automatic updates: a missing key is macOS's default, on; checking off turns both off")
    func updates() {
        #expect(SecurityParsing.updates([:]) == (true, true))
        #expect(SecurityParsing.updates(["AutomaticDownload": 1, "AutomaticallyInstallMacOSUpdates": 0]) == (true, false))
        #expect(SecurityParsing.updates(["CriticalUpdateInstall": false]) == (false, true))
        #expect(SecurityParsing.updates(["AutomaticCheckEnabled": 0]) == (false, false))
    }

    @Test("System extensions under their category; kernel extensions not made by Apple")
    func extensions() {
        let list = """
        2 extension(s)
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tABCDE12345\tcom.example.filter (1.2/34)\tExample Filter\t[activated enabled]
        --- com.apple.system_extension.driver_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tFGHIJ67890\tcom.example.driver (2.0/1)\tExample Driver\t[terminated waiting to uninstall on reboot]
        """
        let found = SecurityParsing.systemExtensions(list)
        #expect(found.map(\.identifier) == ["com.example.filter", "com.example.driver"])
        #expect(found.map(\.category) == ["network_extension", "driver_extension"])
        #expect(found.map(\.isOn) == [true, false])
        #expect(found.first?.version == "1.2" && found.first?.teamID == "ABCDE12345" && found.first?.name == "Example Filter")
        #expect(SecurityParsing.systemExtensions("0 extension(s)\n").isEmpty)
        let kernel = """
        Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
          1  128 0                  0          0          com.apple.kpi.bsd (25.0.0) 1F3E… <>
        190    0 0xfffffe0006b88000 0x8000     0x8000     com.example.kext (3.1.4) 9A2B… <8 6 5 3 1>
        """
        #expect(SecurityParsing.kernelExtensions(kernel).map(\.identifier) == ["com.example.kext"])
        #expect(SecurityParsing.kernelExtensions(kernel).first?.version == "3.1.4")
    }
}

@Suite("Browser extensions (D-261)")
struct BrowserExtensionReadingTests {
    @Test("Access in plain words, broadest first; storage and alarms reach nothing")
    func access() {
        #expect(ExtensionAccess.from(["<all_urls>", "storage", "alarms", "tabs", "nativeMessaging", "https://*.example.com/*"])
            == [.everySite, .tabs, .appsOnMac])
        #expect(ExtensionAccess.from(["https://mail.example.com/*", "cookies"]) == [.someSites, .cookies])
        #expect(ExtensionAccess.from(["storage"]).isEmpty)
    }

    @Test("A Chrome extension: its localized name, every kind of permission, on or off")
    func chromium() throws {
        let manifest: [String: Any] = [
            "name": "__MSG_appName__", "version": "4.2", "default_locale": "en",
            "permissions": ["storage", "tabs"], "host_permissions": ["<all_urls>"],
            "content_scripts": [["matches": ["https://*.example.com/*"]]],
        ]
        let messages: [String: Any] = ["AppName": ["message": "Example Helper"]]
        let on = try #require(BrowserExtensionReading.chromium(
            browser: .chrome, identifier: "abc", manifest: manifest, messages: messages, settings: ["disable_reasons": []]
        ))
        #expect(on.name == "Example Helper" && on.version == "4.2" && on.isOn == true)
        #expect(on.permissions == ["storage", "tabs", "<all_urls>", "https://*.example.com/*"])
        let off = BrowserExtensionReading.chromium(
            browser: .chrome, identifier: "abc", manifest: manifest, messages: nil, settings: ["disable_reasons": [1]]
        )
        #expect(off?.isOn == false && off?.name == "__MSG_appName__")
        #expect(BrowserExtensionReading.chromium(
            browser: .chrome,
            identifier: "abc",
            manifest: manifest,
            messages: nil,
            settings: ["state": 0]
        )?.isOn == false)
        // Built into the browser: not listed.
        #expect(BrowserExtensionReading.chromium(
            browser: .chrome,
            identifier: "abc",
            manifest: manifest,
            messages: nil,
            settings: ["location": 5]
        ) == nil)
    }

    @Test("Firefox: the person's extensions only, with what they were granted")
    func firefox() {
        let json = """
        {"addons":[
          {"id":"ublock@example","type":"extension","location":"app-profile","version":"1.60","active":true,
           "defaultLocale":{"name":"uBlock Example"},"userPermissions":{"permissions":["storage","webRequest"],"origins":["<all_urls>"]}},
          {"id":"formautofill@mozilla.org","type":"extension","location":"app-builtin","version":"1.0","active":true},
          {"id":"dark@mozilla.org","type":"theme","location":"app-profile","version":"1.0","active":true}
        ]}
        """
        let found = BrowserExtensionReading.firefox(Data(json.utf8))
        #expect(found.map(\.name) == ["uBlock Example"])
        #expect(found.first?.access == [.everySite, .webTraffic])
    }

    @Test("Safari: pluginkit's listing, as this Mac prints it")
    func safari() {
        let output = """
             com.1password.safari.extension(8.12.42)
        \t            Path = /Applications/1Password for Safari.app/Contents/PlugIns/1Password.appex
        \t            UUID = 00000000-0000-4000-8000-000000000003
        \t    Display Name = 1Password
        \t     Parent Name = 1Password for Safari

         (1 plug-in)
        """
        let found = BrowserExtensionReading.safari(output)
        #expect(found == [BrowserExtensionReading.SafariListing(
            identifier: "com.1password.safari.extension", version: "8.12.42", name: "1Password",
            path: "/Applications/1Password for Safari.app/Contents/PlugIns/1Password.appex"
        )])
    }
}
