import Core
import Foundation

/// A MacBook Pro closed on a desk with two 4K displays, one on HDMI and one on Thunderbolt, a
/// dock and a keyboard: for previews, tests and Simulated data (D-237).
public struct SimulatedDesk: DeskSource {
    public init() {}

    public func sample(at date: Date) async -> DeskSample {
        DeskSample(at: date, externalDisplays: 2, largestWidth: 3840, largestHeight: 2160, lidClosed: true)
    }

    public func details() async -> DeskDetails {
        DeskDetails(
            displays: [
                DeskDetails.Display(
                    id: 2, name: "LG HDR 4K", isBuiltIn: false, isMain: true, nativeWidth: 3840, nativeHeight: 2160, looksLikeWidth: 2560,
                    looksLikeHeight: 1440, refreshRate: 60, inches: 27, connection: nil, isMirrored: false
                ),
                DeskDetails.Display(
                    id: 3, name: "Dell U2723QE", isBuiltIn: false, isMain: false, nativeWidth: 3840, nativeHeight: 2160,
                    looksLikeWidth: 1920,
                    looksLikeHeight: 1080, refreshRate: 60, inches: 27, connection: nil, isMirrored: false
                ),
            ],
            ports: [
                DeskDetails.Port(name: "USB-C 1", isConnected: true, carries: [.display, .thunderbolt, .usb]),
                DeskDetails.Port(name: "USB-C 2", isConnected: false, carries: []),
                DeskDetails.Port(name: "USB-C 3", isConnected: true, carries: [.power]),
                DeskDetails.Port(name: "HDMI", isConnected: true, carries: [.display]),
                DeskDetails.Port(name: "MagSafe", isConnected: false, carries: []),
            ],
            devices: [
                DeskDetails.WiredDevice(name: "TS4", maker: "CalDigit, Inc.", speed: "Up to 40 Gb/s", isThunderbolt: true),
                DeskDetails.WiredDevice(name: "Magic Keyboard with Touch ID", maker: "Apple Inc.", speed: "12 Mb/s", isThunderbolt: false),
                DeskDetails.WiredDevice(name: "USB Audio Device", maker: "Focusrite", speed: "480 Mb/s", isThunderbolt: false),
            ],
            lidClosed: true
        )
    }
}

extension SimulatedHistoryStore: DeskHistoryStore {
    public func recordDesk(_: DeskSample) async throws {}

    /// A month at a desk, lid closed, two displays, with a few days out.
    public func deskSamples(from: Date, to: Date) async throws -> [DeskSample] {
        stride(from: max(from.timeIntervalSince1970, to.timeIntervalSince1970 - 30 * 86400), to: to.timeIntervalSince1970, by: 600)
            .map { t in
                let away = Int(t / 86400).isMultiple(of: 7)
                return DeskSample(
                    at: Date(timeIntervalSince1970: t), externalDisplays: away ? 0 : 2, largestWidth: away ? 0 : 3840,
                    largestHeight: away ? 0 : 2160,
                    lidClosed: !away
                )
            }
    }
}
