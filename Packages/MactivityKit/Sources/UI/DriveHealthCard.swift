import Core
import SwiftUI

/// Each drive's own health report on the Disk tab (D-157): "APPLE SSD AP2048Z · Good · 0% of
/// rated life used · 7.4 TB written · 122 hours on". Read once when the tab shows.
struct DriveHealthCard: View {
    let services: AppServices
    @State private var drives: [DriveHealth] = []

    var body: some View {
        Group {
            if !drives.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        ForEach(drives) { drive in
                            HStack(spacing: Tokens.Spacing.s) {
                                Image(systemName: Self.symbol(drive.verdict))
                                    .foregroundStyle(Self.tint(drive.verdict))
                                Text(Self.line(drive))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                            }
                            .help(Text(drive.problem ?? Self.details(drive)))
                        }
                    }
                }
            }
        }
        .task { drives = await services.driveHealth.drives() }
    }

    static func symbol(_ verdict: DriveHealth.Verdict) -> String {
        switch verdict {
        case .good: "checkmark.circle"
        case .worn: "exclamationmark.circle"
        case .failing: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ verdict: DriveHealth.Verdict) -> Color {
        switch verdict {
        case .good: .secondary
        case .worn: Tokens.Colors.strain
        case .failing: .red
        }
    }

    static func verdictTitle(_ verdict: DriveHealth.Verdict) -> String {
        switch verdict {
        case .good: String(localized: "Good", bundle: .strings, comment: "Drive health")
        case .worn: String(localized: "Wearing out", bundle: .strings, comment: "Drive health")
        case .failing: String(localized: "Reports a problem", bundle: .strings, comment: "Drive health")
        }
    }

    static func line(_ drive: DriveHealth) -> String {
        let used = Formatters.percent(Double(drive.percentUsed))
        let written = Formatters.bytes(drive.bytesWritten)
        return [
            drive.model,
            verdictTitle(drive.verdict),
            String(localized: "\(used) of rated life used", bundle: .strings, comment: "Drive wear, e.g. 2% of rated life used"),
            String(localized: "\(written) written", bundle: .strings, comment: "Data written over the drive's life"),
        ].joined(separator: " · ")
    }

    /// The tooltip: hours on, spare, temperature, unexpected power losses.
    static func details(_ drive: DriveHealth) -> String {
        let hours = drive.powerOnHours.formatted()
        let spare = Formatters.percent(Double(drive.availableSpare))
        var parts = [
            String(localized: "\(hours) hours on", bundle: .strings, comment: "Drive power-on hours"),
            String(localized: "Spare \(spare)", bundle: .strings, comment: "Drive's remaining spare blocks"),
        ]
        if let celsius = drive.temperatureCelsius {
            parts.append(Formatters.temperature(celsius: celsius))
        }
        parts.append(String(localized: "Unexpected power losses: \(drive.unsafeShutdowns)", bundle: .strings))
        return parts.joined(separator: " · ")
    }
}
