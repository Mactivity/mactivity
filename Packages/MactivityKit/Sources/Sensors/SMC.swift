import Foundation
import IOKit
import os

/// A connection to the AppleSMC user client (public IOKit calls; the key protocol is the one
/// every Mac monitor uses, adapted with reference to Stats by exelban, MIT). Not thread-safe:
/// owned by `SensorSampler`.
final class SMC {
    private static let log = Logger(subsystem: "app.mactivity.sensors", category: "smc")

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private let connection: io_connect_t
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    init?() {
        guard MemoryLayout<SMCParam>.stride == 80 else {
            Self.log.fault("SMC struct layout is \(MemoryLayout<SMCParam>.stride) bytes, expected 80")
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Reads a key's value as (type, bytes).
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code) else {
            return nil
        }
        var input = SMCParam()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readBytes.rawValue
        guard let output = call(&input) else {
            return nil
        }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) }
        return (Self.string(info.dataType), bytes)
    }

    func value(_ key: String) -> Double? {
        read(key).flatMap { SensorKeys.decode(type: $0.type, bytes: $0.bytes) }
    }

    /// Every key the SMC has (about 3,600 on an M5 Pro, ~120 ms). Done once per launch.
    func allKeys() -> [String] {
        guard let count = value("#KEY").map(Int.init), count > 0 else {
            return []
        }
        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0 ..< count {
            var input = SMCParam()
            input.command = Command.readIndex.rawValue
            input.data32 = UInt32(index)
            if let output = call(&input) {
                keys.append(Self.string(output.key))
            }
        }
        return keys
    }

    private func keyInfo(_ code: UInt32) -> SMCKeyInfo? {
        if let cached = infoCache[code] {
            return cached
        }
        var input = SMCParam()
        input.key = code
        input.command = Command.readKeyInfo.rawValue
        guard let info = call(&input)?.keyInfo else {
            return nil
        }
        infoCache[code] = info
        return info
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return status == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    static func fourCC(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? "????"
    }
}

// `SMCKeyData_t`, laid out to match the kernel's C struct (80 bytes). Swift puts a struct's
// next field right after the previous one's size, so the key info carries explicit padding.

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimit {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    // A C `char[32]` imports as a 32-element tuple; the layout has to match the kernel's.
    // swiftlint:disable:next large_tuple
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
