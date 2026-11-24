import CoreBluetooth
import UI

/// Asks for Bluetooth access on purpose, from onboarding or Settings, so AirPods batteries can be
/// read. Nothing else prompts: `BluetoothBatteries` stays away from IOBluetooth until access is
/// granted, because `pairedDevices` blocks the main thread until the prompt is answered.
@MainActor
final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothAccess()

    private var manager: CBCentralManager?
    private var waiting: [CheckedContinuation<AccessoryBatteryAccess, Never>] = []

    override private init() {
        super.init()
    }

    /// Reading the status never prompts.
    static var status: AccessoryBatteryAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Shows the system prompt once; returns when the user answers.
    func request() async -> AccessoryBatteryAccess {
        guard Self.status == .notAsked else {
            return Self.status
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if manager == nil {
                // Creating a central manager is what shows the prompt.
                manager = CBCentralManager(delegate: self, queue: nil)
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_: CBCentralManager) {
        // queue: nil delivers on the main queue.
        MainActor.assumeIsolated { finishIfAnswered() }
    }

    private func finishIfAnswered() {
        let status = Self.status
        guard status != .notAsked else {
            return
        }
        waiting.forEach { $0.resume(returning: status) }
        waiting = []
        manager = nil
    }
}
