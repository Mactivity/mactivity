import AppKit
import Core
import Observation
import SwiftUI

/// The Devices page's state (D-237): the details when it shows and every 30 seconds while it
/// does, the desk's month from History once a visit.
@MainActor
@Observable
final class DevicesModel {
    private let source: any DeskSource
    private(set) var details: DeskDetails?
    private(set) var month: DeskUsage?

    init(source: any DeskSource) {
        self.source = source
    }

    func load() async {
        details = await source.details()
    }

    func loadMonth(_ history: any HistoryStore, now: Date = Date()) async {
        guard let desk = history as? any DeskHistoryStore else {
            return
        }
        month = await DeskUsage.from((try? desk.deskSamples(from: now.addingTimeInterval(-30 * 86400), to: now)) ?? [])
    }
}

/// Devices (D-237): every display with its resolution, scaling, refresh and connection, each
/// port and what's on it, the wired devices, the lid, how the desk has been used this month, and
/// which apps used the camera and microphone (D-259).
/// Settings stay in System Settings; this page shows them and links there.
struct DevicesView: View {
    let services: AppServices

    private var model: DevicesModel {
        services.devices
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
                header
                if let details = model.details {
                    displays(details)
                    HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                        ports(details)
                        wired(details)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                // Which apps used the camera and microphone (1.8, D-259).
                SensorHistoryCard(services: services)
            }
            .padding(Tokens.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            await model.loadMonth(services.history)
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                Text(model.details.map(DevicesText.summary) ?? SidebarItem.devices.title)
                    .font(Tokens.Typography.cardTitle)
                if let month = model.month {
                    Text(DevicesText.month(month))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "Displays Settings…", bundle: .strings, comment: "Opens System Settings at Displays")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .cardStyle()
    }

    private func displays(_ details: DeskDetails) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Displays", bundle: .strings, comment: "Devices page: section title")
                .font(Tokens.Typography.cardTitle)
            ForEach(details.displays) { display in
                DisplayRow(display: display)
                if display.id != details.displays.last?.id {
                    Divider()
                }
            }
            if details.lidClosed == true {
                Label {
                    Text("The lid is closed: the Mac is running on its external displays.", bundle: .strings)
                } icon: {
                    Image(systemName: "laptopcomputer")
                }
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func ports(_ details: DeskDetails) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Ports", bundle: .strings, comment: "Devices page: section title").font(Tokens.Typography.cardTitle)
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
                ForEach(details.ports) { port in
                    GridRow {
                        Text(verbatim: port.name).monospacedDigit()
                        Text(DevicesText.carries(port))
                            .foregroundStyle(port.isConnected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(Tokens.Typography.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func wired(_ details: DeskDetails) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Plugged in", bundle: .strings, comment: "Devices page: wired USB and Thunderbolt devices")
                .font(Tokens.Typography.cardTitle)
            if details.devices.isEmpty {
                Text("No USB or Thunderbolt devices.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(details.devices) { device in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    Image(systemName: device.isThunderbolt ? "bolt.horizontal" : "cable.connector.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.IconSize.row)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                        Text(device.name)
                        if let maker = device.maker {
                            Text(maker).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let speed = device.speed {
                        Text(speed).font(Tokens.Typography.secondary).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct DisplayRow: View {
    let display: DeskDetails.Display

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.title2)
                .foregroundStyle(Tokens.SidebarTint.devices)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(display.name).font(Tokens.Typography.rowTitle)
                    if display.isMain {
                        Text("Main", bundle: .strings, comment: "Devices page: the display with the menu bar")
                            .font(Tokens.Typography.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(DevicesText.panel(display))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                Text(DevicesText.setting(display))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Tokens.Spacing.lineGap) {
                Text(DevicesText.refresh(display.refreshRate)).monospacedDigit()
                Text(display.isBuiltIn
                    ? String(localized: "Built in", bundle: .strings, comment: "Devices page: the Mac's own screen")
                    : display.connection ?? String(
                        localized: "External",
                        bundle: .strings,
                        comment: "Devices page: a display, connection unknown"
                    ))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Devices page's words.
enum DevicesText {
    /// "2 external displays · 3 devices plugged in".
    static func summary(_ details: DeskDetails) -> String {
        let externals = details.displays.filter { !$0.isBuiltIn }.count
        let displays = switch externals {
        case 0: String(localized: "No external display", bundle: .strings, comment: "Devices page summary")
        case 1: String(localized: "1 external display", bundle: .strings, comment: "Devices page summary")
        default: String(localized: "\(externals) external displays", bundle: .strings, comment: "Devices page summary")
        }
        let devices = details.devices.count
        guard devices > 0 else {
            return displays
        }
        let plugged = devices == 1
            ? String(localized: "1 device plugged in", bundle: .strings, comment: "Devices page summary")
            : String(localized: "\(devices) devices plugged in", bundle: .strings, comment: "Devices page summary")
        return "\(displays) · \(plugged)"
    }

    /// "This month: displays connected 85% of the time, lid closed 70%".
    static func month(_ usage: DeskUsage) -> String {
        let docked = Formatters.percent(usage.dockedShare * 100)
        let closed = Formatters.percent(usage.closedShare * 100)
        return String(
            localized: "This month: displays connected \(docked) of the time, lid closed \(closed)",
            bundle: .strings,
            comment: "Devices page: how the desk was used over 30 days"
        )
    }

    /// "4K · 3840 × 2160 · 27-inch".
    static func panel(_ display: DeskDetails.Display) -> String {
        var parts = ["\(display.nativeWidth) × \(display.nativeHeight)"]
        let name = DeskUsage.name(width: display.nativeWidth, height: display.nativeHeight)
        if !name.contains("×") {
            parts.insert(name, at: 0)
        }
        if let inches = display.inches, inches >= 10 {
            parts.append(String(
                localized: "\(Int(inches.rounded()))-inch",
                bundle: .strings,
                comment: "Devices page: a display's size, e.g. 27-inch"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// "Looks like 2560 × 1440, scaled" or "Looks like 1920 × 1080, sharpest".
    static func setting(_ display: DeskDetails.Display) -> String {
        let looks = "\(display.looksLikeWidth) × \(display.looksLikeHeight)"
        return display.isScaled
            ? String(
                localized: "Looks like \(looks), scaled: sharp, at a little extra work for the graphics",
                bundle: .strings,
                comment: "Devices page: a scaled resolution"
            )
            : String(localized: "Looks like \(looks)", bundle: .strings, comment: "Devices page: the resolution setting")
    }

    static func refresh(_ hertz: Double) -> String {
        hertz > 0 ? "\(Int(hertz.rounded())) Hz" : "–"
    }

    /// "Display, Thunderbolt", "USB", "Power", "Nothing".
    static func carries(_ port: DeskDetails.Port) -> String {
        guard port.isConnected, !port.carries.isEmpty else {
            return String(localized: "Nothing plugged in", bundle: .strings, comment: "Devices page: an empty port")
        }
        return port.carries.map { carry in
            switch carry {
            case .display: String(localized: "Display", bundle: .strings, comment: "Devices page: a port carrying a display")
            case .thunderbolt: "Thunderbolt"
            case .usb: "USB"
            case .power: String(localized: "Power", bundle: .strings, comment: "Devices page: a port only charging")
            }
        }.formatted(.list(type: .and))
    }
}
