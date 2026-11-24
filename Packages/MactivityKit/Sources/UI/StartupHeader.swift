import Startup
import SwiftUI

// MARK: - Header

struct StartupHeader: View {
    let model: StartupModel

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(model.hasLoaded ? model.summary.line : String(localized: "Looking at what starts with your Mac…", bundle: .strings))
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                // The footnote's line is there before the load too, so the header keeps its height.
                Text(model.hasLoaded ? model.summary.footnote : String(localized: "Reading launch agents and daemons…", bundle: .strings))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(model.hasLoaded ? model.summary.footnote : "")
            }
            Spacer()
            Button(String(localized: "Login Items Settings…", bundle: .strings)) { StartupActions.openLoginItemsSettings() }
                .help(Text("Opens System Settings → General → Login Items & Extensions, the complete list.", bundle: .strings))
        }
        .cardStyle()
    }
}
