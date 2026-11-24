import Core
import Foundation

/// The system's thermal pressure from `ProcessInfo.thermalState`. Public API only; a plain
/// read, so no actor.
public enum ThermalReader {
    public static func current() -> ThermalPressure {
        pressure(ProcessInfo.processInfo.thermalState)
    }

    static func pressure(_ state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        // A state added after macOS 27 has no meaning we can rank; don't raise a false alarm.
        @unknown default: .nominal
        }
    }
}
