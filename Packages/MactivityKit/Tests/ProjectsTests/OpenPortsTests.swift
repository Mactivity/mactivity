import Foundation
@testable import Projects
import Testing

/// Open to the network (D-230).
struct OpenPortsTests {
    @Test("Every interface or a network address is open; loopback isn't")
    func open() {
        #expect(OpenPortRules.isOpen("*"))
        #expect(OpenPortRules.isOpen("192.168.1.24"))
        #expect(OpenPortRules.isOpen("fe80::1"))
        #expect(!OpenPortRules.isOpen("127.0.0.1"))
        #expect(!OpenPortRules.isOpen("::1"))
        #expect(!OpenPortRules.isOpen("::ffff:127.0.0.1"))
    }

    @Test("The firewall's state from socketfilterfw, by its number")
    func firewall() {
        #expect(OpenPortRules.firewallState("Firewall is disabled. (State = 0)\n") == false)
        #expect(OpenPortRules.firewallState("Firewall is enabled. (State = 1)\n") == true)
        #expect(OpenPortRules.firewallState("Firewall is blocking all non-essential incoming connections. (State = 2)") == true)
        #expect(OpenPortRules.firewallState("Firewall stealth mode is on") == true)
        #expect(OpenPortRules.firewallState("Firewall stealth mode is off") == false)
        #expect(OpenPortRules.firewallState("") == nil)
    }

    @Test("macOS's AirPlay Receiver is named, with where to turn it off")
    func known() {
        #expect(OpenPortRules.known(processName: "ControlCenter", port: 7000)?.contains("AirPlay") == true)
        #expect(OpenPortRules.known(processName: "ControlCenter", port: 12345) == nil)
        #expect(OpenPortRules.known(processName: "node", port: 3000) == nil)
    }
}
