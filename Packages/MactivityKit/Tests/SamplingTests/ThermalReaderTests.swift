import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Thermal reader")
struct ThermalReaderTests {
    @Test(
        "Every ProcessInfo thermal state maps to its ThermalPressure",
        arguments: [
            (ProcessInfo.ThermalState.nominal, ThermalPressure.nominal),
            (.fair, .fair),
            (.serious, .serious),
            (.critical, .critical),
        ]
    )
    func mapping(state: ProcessInfo.ThermalState, expected: ThermalPressure) {
        #expect(ThermalReader.pressure(state) == expected)
    }

    @Test("The live reading matches ProcessInfo")
    func live() {
        #expect(ThermalReader.current() == ThermalReader.pressure(ProcessInfo.processInfo.thermalState))
    }
}
