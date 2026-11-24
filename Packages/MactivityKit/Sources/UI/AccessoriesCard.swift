import Core
import SwiftUI

/// The Battery tab's Bluetooth accessories (D-165): each one's kind, name and charge, at most
/// four rows so the card never grows taller than the headline beside it.
struct AccessoriesCard: View {
    let accessories: [PeripheralBattery]
    /// The narrow card beside the figures: no bar, so "AirPods Pro" keeps its name.
    var showsBars = true
    static let maxRows = 4
    /// At or under this, the bar and figure turn red.
    static let lowPercent = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Accessories", bundle: .strings, comment: "Battery tab card: Bluetooth keyboards, mice, AirPods")
                .font(Tokens.Typography.secondary.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(accessories.prefix(Self.maxRows)) { accessory in
                row(accessory)
            }
            if accessories.count > Self.maxRows {
                let more = accessories.count - Self.maxRows
                Text("\(more) more", bundle: .strings, comment: "Accessories card: rows not shown")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .help(accessories.dropFirst(Self.maxRows).map { "\($0.name) \(Formatters.percent($0.percent))" }
                        .joined(separator: "\n"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle()
    }

    private func row(_ accessory: PeripheralBattery) -> some View {
        let low = accessory.percent <= Self.lowPercent
        return HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: Self.symbol(accessory.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(accessory.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Tokens.Spacing.xs)
            if showsBars {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 26, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(low ? Color.red : MetricTab.battery.tint)
                            .frame(width: max(3, 26 * min(1, accessory.percent / 100)), height: 6)
                    }
            }
            Text(Formatters.percent(accessory.percent))
                .monospacedDigit()
                .foregroundStyle(low ? Color.red : .primary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .help(accessory.name)
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ kind: PeripheralBattery.Kind) -> String {
        switch kind {
        case .airPods: "airpodspro"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "hand.point.up.left"
        case .other: "battery.75percent"
        }
    }
}
