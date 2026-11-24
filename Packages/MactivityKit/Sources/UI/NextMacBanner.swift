import SwiftUI

/// History's way into "Your next Mac" (D-181): a card of its own under Your week, where a menu
/// item behind Save Report was too easy to miss.
struct NextMacBanner: View {
    let services: AppServices

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: services.metrics.hardware.hasBattery ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LinearGradient(colors: NextMacPage.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Your next Mac", bundle: .strings, comment: "Report title: what to look for in a new Mac")
                    .font(Tokens.Typography.cardTitle)
                Text(
                    "The chip, memory and storage to look for in a new Mac, from how you use this one.",
                    bundle: .strings,
                    comment: "History: what the Your next Mac report says"
                )
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: Tokens.Spacing.s)
            Button(String(localized: "Open Report", bundle: .strings, comment: "Opens the Your next Mac report")) {
                services.nextMac.open()
            }
            .fixedSize()
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
    }
}
