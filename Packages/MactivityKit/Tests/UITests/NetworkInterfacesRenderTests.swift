import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// The interfaces list (D-264), from the simulated Mac.
extension NewFeaturesRenderTests {
    @Test("Network interfaces")
    func networkInterfaces() async throws {
        let model = NetworkInterfacesModel(source: SimulatedNetworkInterfaces())
        await model.refresh()
        // A real window size, where the facts once sat centered and narrow, then the narrowest.
        try await write(NetworkInterfacesCard(model: model).padding(), name: "network-interfaces", size: CGSize(width: 1040, height: 620))
        try await write(
            NetworkInterfacesCard(model: model).padding(),
            name: "network-interfaces-narrow",
            size: CGSize(width: 620, height: 900)
        )
    }

    @Test("An interface with little to say leaves no empty columns or groups")
    @MainActor
    func columnsSkipEmpties() {
        let port = NetworkInterfaceInfo(name: "en3", displayName: nil, kind: .ethernet, status: .notConnected, mtu: 1500)
        let columns = NetworkInterfaceText.columns(port)
        #expect(columns.map { $0.map(\.id) } == [["addresses"], ["connection"]])
        #expect(NetworkInterfaceText.abilities(port) == nil)
        #expect(NetworkInterfaceText.columns(port, count: 1).map { $0.map(\.id) } == [["addresses", "connection"]])
    }

    @Test("Each fact says what it means")
    @MainActor
    func everyRowExplains() async {
        for item in await SimulatedNetworkInterfaces().interfaces() {
            for row in NetworkInterfaceText.rows(item) {
                #expect(!row.help.isEmpty && !row.label.isEmpty && !row.value.isEmpty, "\(item.name) \(row.id)")
            }
        }
    }
}
