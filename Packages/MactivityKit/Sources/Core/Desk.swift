import Foundation

/// The Mac's desk setup at one moment (1.5.1, D-237): external displays and the lid. Read every
/// 10 minutes into History, cheaply (CoreGraphics and one IORegistry property), so the Next Mac
/// advice knows how the Mac is really used.
public struct DeskSample: Sendable, Hashable, Codable {
    public let at: Date
    public let externalDisplays: Int
    /// The largest external display's pixels, 0 without one.
    public let largestWidth: Int
    public let largestHeight: Int
    /// Nil on a Mac without a lid.
    public let lidClosed: Bool?

    public init(at: Date, externalDisplays: Int, largestWidth: Int, largestHeight: Int, lidClosed: Bool?) {
        self.at = at
        self.externalDisplays = externalDisplays
        self.largestWidth = largestWidth
        self.largestHeight = largestHeight
        self.lidClosed = lidClosed
    }
}

public protocol DeskHistoryStore: Sendable {
    func recordDesk(_ sample: DeskSample) async throws
    func deskSamples(from: Date, to: Date) async throws -> [DeskSample]
}

/// The desk over a span (D-237): how often displays were connected, how many, and how often the
/// lid was closed. Pure.
public struct DeskUsage: Sendable, Hashable {
    public let samples: Int
    /// Share of the time with an external display connected.
    public let dockedShare: Double
    /// Share of the time with the lid closed: in clamshell, on a laptop.
    public let closedShare: Double
    /// How many external displays, most often, when there were any.
    public let externalDisplays: Int
    /// The largest external display seen, pixels.
    public let largestWidth: Int
    public let largestHeight: Int

    public init(samples: Int, dockedShare: Double, closedShare: Double, externalDisplays: Int, largestWidth: Int, largestHeight: Int) {
        self.samples = samples
        self.dockedShare = dockedShare
        self.closedShare = closedShare
        self.externalDisplays = externalDisplays
        self.largestWidth = largestWidth
        self.largestHeight = largestHeight
    }

    /// Nil under a day's worth of samples (144 at 10 minutes): too little to say how the Mac is used.
    public static func from(_ samples: [DeskSample], minimum: Int = 144) -> DeskUsage? {
        guard samples.count >= minimum else {
            return nil
        }
        let docked = samples.filter { $0.externalDisplays > 0 }
        var counts: [Int: Int] = [:]
        for sample in docked {
            counts[sample.externalDisplays, default: 0] += 1
        }
        let usual = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key ?? 0
        let largest = samples.max { $0.largestWidth * $0.largestHeight < $1.largestWidth * $1.largestHeight }
        return DeskUsage(
            samples: samples.count,
            dockedShare: Double(docked.count) / Double(samples.count),
            closedShare: Double(samples.filter { $0.lidClosed == true }.count) / Double(samples.count),
            externalDisplays: usual,
            largestWidth: largest?.largestWidth ?? 0,
            largestHeight: largest?.largestHeight ?? 0
        )
    }

    /// At a desk most of the time: displays connected over half of it.
    public var isMostlyDocked: Bool {
        dockedShare >= 0.5
    }

    /// Closed on the desk most of the time.
    public var isMostlyClosed: Bool {
        closedShare >= 0.5
    }

    /// "4K", "5K", "6K", or the pixels: what a display is called by its width.
    public static func name(width: Int, height: Int) -> String {
        switch width {
        case 6016...: "6K"
        case 5120...: "5K"
        case 3840...: "4K"
        case 2560...: "\(width) × \(height)"
        default: "\(width) × \(height)"
        }
    }
}

/// Everything on the Devices page (D-237): displays, ports and what's on them, wired devices.
public struct DeskDetails: Sendable, Hashable {
    public struct Display: Sendable, Hashable, Identifiable {
        public let id: UInt32
        public let name: String
        public let isBuiltIn: Bool
        public let isMain: Bool
        /// The panel's own pixels.
        public let nativeWidth: Int
        public let nativeHeight: Int
        /// What it's set to look like, in points.
        public let looksLikeWidth: Int
        public let looksLikeHeight: Int
        public let refreshRate: Double
        /// Diagonal, inches, from the size it reports.
        public let inches: Double?
        /// "HDMI", "USB-C or Thunderbolt", "Built-in"; nil when it can't be told.
        public let connection: String?
        public let isMirrored: Bool

        public init(
            id: UInt32, name: String, isBuiltIn: Bool, isMain: Bool, nativeWidth: Int, nativeHeight: Int, looksLikeWidth: Int,
            looksLikeHeight: Int, refreshRate: Double, inches: Double?, connection: String?, isMirrored: Bool
        ) {
            self.id = id
            self.name = name
            self.isBuiltIn = isBuiltIn
            self.isMain = isMain
            self.nativeWidth = nativeWidth
            self.nativeHeight = nativeHeight
            self.looksLikeWidth = looksLikeWidth
            self.looksLikeHeight = looksLikeHeight
            self.refreshRate = refreshRate
            self.inches = inches
            self.connection = connection
            self.isMirrored = isMirrored
        }

        /// Scaled: set to look like more or less than the panel at 2×, so macOS draws more pixels
        /// than it shows and scales them down.
        public var isScaled: Bool {
            looksLikeWidth * 2 != nativeWidth && looksLikeWidth != nativeWidth
        }
    }

    /// A port on the Mac and what's on it.
    public struct Port: Sendable, Hashable, Identifiable {
        public let name: String
        public let isConnected: Bool
        public let carries: [DeskPortContent]

        public var id: String {
            name
        }

        public init(name: String, isConnected: Bool, carries: [DeskPortContent]) {
            self.name = name
            self.isConnected = isConnected
            self.carries = carries
        }
    }

    public struct WiredDevice: Sendable, Hashable, Identifiable {
        public let name: String
        public let maker: String?
        /// "480 Mb/s", "10 Gb/s", "40 Gb/s".
        public let speed: String?
        public let isThunderbolt: Bool

        public var id: String {
            name + (maker ?? "") + (speed ?? "")
        }

        public init(name: String, maker: String?, speed: String?, isThunderbolt: Bool) {
            self.name = name
            self.maker = maker
            self.speed = speed
            self.isThunderbolt = isThunderbolt
        }
    }

    public let displays: [Display]
    public let ports: [Port]
    public let devices: [WiredDevice]
    public let lidClosed: Bool?

    public init(displays: [Display], ports: [Port], devices: [WiredDevice], lidClosed: Bool?) {
        self.displays = displays
        self.ports = ports
        self.devices = devices
        self.lidClosed = lidClosed
    }
}

/// The desk now: a cheap sample for History, or the Devices page's details.
public protocol DeskSource: Sendable {
    func sample(at: Date) async -> DeskSample
    func details() async -> DeskDetails
}

/// What a port carries (D-237).
public enum DeskPortContent: String, Sendable, Hashable, CaseIterable {
    case display, thunderbolt, usb, power
}
